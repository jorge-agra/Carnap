{-#LANGUAGE DeriveGeneric #-}
module Handler.Instuctor where

import Import
import Util.Data
import Util.Database
import Yesod.Form.Bootstrap3
import Yesod.Form.Jquery
import Handler.User (scoreByIdAndClass)
import Text.Blaze.Html (toMarkup)
import Data.Time
import Data.Aeson (decode,encode)
import qualified Data.IntMap (insert,fromList,toList,delete)
import qualified Data.Text as T
import System.FilePath
import System.Directory (getDirectoryContents,removeFile, doesFileExist)


putInstructorR :: Text -> Handler Value
putInstructorR _ = do
    ((assignmentrslt,_),enctypeUploadAssignment) <- runFormPost (identifyForm "updateAssignment" $ updateAssignmentForm)
    case assignmentrslt of 
        (FormSuccess (filename,mdue,mdesc)) -> do
                         massignent <- runDB $ getBy $ UniqueAssignment filename
                         case massignent of 
                               Nothing -> return ()
                               Just assignent -> runDB $ do maybeDo mdue (\due -> update (entityKey assignent) 
                                                                            [ AssignmentMetadataDuedate =. (Just $ UTCTime due 0) ])
                                                            maybeDo mdesc (\desc -> update (entityKey assignent) 
                                                                            [ AssignmentMetadataDescription =. (Just $ unTextarea desc) ])

                                                        
                         case mdue of Nothing -> returnJson ([filename,"No Due Date"])
                                      Just due -> returnJson ([filename,pack $ show $ UTCTime due 0])
        (FormFailure s) -> returnJson ("error" :: Text)
        FormMissing -> returnJson ("no form" :: Text)
    where maybeDo mv f = case mv of Just v -> f v; _ -> return ()

deleteInstructorR :: Text -> Handler Value
deleteInstructorR ident = do
    msg <- requireJsonBody :: Handler InstructorDelete
    case msg of 
      DeleteAssignment fn ->
        do adir <- assignmentDir 
           deleted <- runDB $ do mk <- getBy $ UniqueAssignment fn
                                 case mk of
                                     Just (Entity k v) -> do syn <- selectList [SyntaxCheckSubmissionAssignmentId ==. Just k] []
                                                             ders <- selectList [DerivationSubmissionAssignmentId ==. Just k] []
                                                             trans <- selectList [TranslationSubmissionAssignmentId ==. Just k] []
                                                             trutht <- selectList [TruthTableSubmissionAssignmentId ==. Just k] []
                                                             mapM (delete . entityKey) syn
                                                             mapM (delete . entityKey) ders
                                                             mapM (delete . entityKey) trans
                                                             mapM (delete . entityKey) trutht
                                                             delete k
                                                             liftIO $ do fe <- doesFileExist (adir </> unpack fn) 
                                                                         if fe then removeFile (adir </> unpack fn)
                                                                               else return ()
                                                             return True
                                     Nothing -> return False
           if deleted 
               then returnJson (fn ++ " deleted")
               else returnJson ("unable to retrieve metadata for " ++ fn)
      DeleteProblems coursename setnum -> 
            do miid <- instructorIdByIdent ident
               case miid of
                   Just iid -> 
                        do mclass <- runDB $ getBy $ UniqueCourse coursename iid
                           case mclass of 
                                Just theclass ->
                                    do let assignmentBytes = fromStrict . courseTextbookProblems . entityVal $ theclass
                                       case decode assignmentBytes :: Maybe (IntMap UTCTime)  of
                                           Just assign -> do runDB $ update (entityKey theclass) 
                                                                            [CourseTextbookProblems =. (toStrict . encode $ Data.IntMap.delete setnum assign)]
                                                             returnJson ("Deleted"::Text)
                                           Nothing -> returnJson ("Yikes. Assignment table corrupted somehow."::Text)
                                Nothing -> returnJson ("Something went wrong with retriving the course."::Text)

                   Nothing -> returnJson ("You do not appear to be an instructor."::Text)

postInstructorR :: Text -> Handler Html
postInstructorR ident = do
    classes <- classesByInstructorIdent ident
    ((assignmentrslt,_),_) <- runFormPost (identifyForm "uploadAssignment" $ uploadAssignmentForm classes)
    ((newclassrslt,_),_) <- runFormPost (identifyForm "createCourse" createCourseForm)
    ((frombookrslt,_),_) <- runFormPost (identifyForm "setBookAssignment" $ setBookAssignmentForm classes)
    case assignmentrslt of 
        (FormSuccess (file, theclass, duedate, assignmentdesc, subtime)) ->
            do let fn = fileName file
                   duetime = UTCTime <$> duedate <*> Just 0
                   info = unTextarea <$> assignmentdesc
               success <- tryInsert $ AssignmentMetadata fn info duetime subtime (entityKey theclass)
               if success then saveAssignment file 
                          else setMessage "Could not save---this file already exists"
        (FormFailure s) -> setMessage $ "Something went wrong: " ++ toMarkup (show s)
        FormMissing -> return ()
    case newclassrslt of
        (FormSuccess (title, coursedesc, startdate, enddate)) -> do
            miid <- instructorIdByIdent ident
            case miid of
                Just iid -> 
                    do success <- tryInsert $ Course title (unTextarea <$> coursedesc) iid "" (UTCTime startdate 0) (UTCTime enddate 0) 0
                       if success then setMessage "Course Created" 
                                  else setMessage "Could not save---this file already exists"
                Nothing -> setMessage "you're not an instructor!"
        (FormFailure s) -> setMessage $ "Something went wrong: " ++ toMarkup (show s)
        FormMissing -> return ()
    case frombookrslt of
        (FormSuccess (theclass, theassignment, duedate)) -> runDB $ do
            let assignmentBytes = fromStrict . courseTextbookProblems . entityVal $ theclass
                duetime = UTCTime duedate 0
            case decode assignmentBytes :: Maybe (IntMap UTCTime)  of
                Just assign -> update (entityKey theclass) [CourseTextbookProblems =. (toStrict . encode $ Data.IntMap.insert theassignment duetime assign)]
                Nothing -> update (entityKey theclass) [CourseTextbookProblems =. (toStrict . encode $ Data.IntMap.fromList [(theassignment, duetime)])]
        (FormFailure s) -> setMessage $ "Something went wrong: " ++ toMarkup (show s)
        FormMissing -> return ()
    redirect $ InstructorR ident

getInstructorR :: Text -> Handler Html
getInstructorR ident = do
    musr <- runDB $ getBy $ UniqueUser ident
    case musr of 
        Nothing -> defaultLayout nopage
        (Just (Entity uid _))  -> do
            UserData firstname lastname enrolledin _ _ <- checkUserData uid 
            classes <- classesByInstructorIdent ident 
            let tags = map (\n -> "id"  ++ (show n)) $ take (length classes) [1 ..]
            classWidgets <- mapM classWidget classes
            instructorCourses <- classesByInstructorIdent ident
            assignmentMetadata <- concat <$> mapM (assignmentsOf . entityKey) classes
            assignmentCourses <- forM assignmentMetadata $ \c -> do 
                                    Just e <- runDB $ get (assignmentMetadataCourse c)
                                    return e
            (uploadAssignmentWidget,enctypeUploadAssignment) <- generateFormPost (identifyForm "uploadAssignment" $ uploadAssignmentForm classes)
            (setBookAssignmentWidget,enctypeSetBookAssignment) <- generateFormPost (identifyForm "setBookAssignment" $ setBookAssignmentForm classes)
            (updateAssignmentWidget,enctypeUpdateAssignment) <- generateFormPost (identifyForm "updateAssignment" $ updateAssignmentForm)
            (createCourseWidget,enctypeCreateCourse) <- generateFormPost (identifyForm "createCourse" createCourseForm)
            defaultLayout $ do
                 addScript $ StaticR js_bootstrap_bundle_min_js
                 addScript $ StaticR js_bootstrap_min_js
                 setTitle $ "Instructor Page for " ++ toMarkup firstname ++ " " ++ toMarkup lastname
                 $(widgetFile "instructor")
    where assignmentsOf theclass = map entityVal <$> listAssignmentMetadata theclass
          mprobsOf course = decode . fromStrict . courseTextbookProblems $ course :: Maybe (IntMap UTCTime)
          nopage = [whamlet|
                    <div.container>
                        <p> Instructor not found.
                   |]

---------------------
--  Message Types  --
---------------------

data InstructorDelete = DeleteAssignment Text
                      | DeleteProblems Text Int
    deriving Generic

instance ToJSON InstructorDelete

instance FromJSON InstructorDelete

------------------
--  Components  --
------------------
updateWidget form enc = [whamlet|
                    <div class="modal fade" id="updateAssignmentData" tabindex="-1" role="dialog" aria-labelledby="updateAssignmentDataLabel" aria-hidden="true">
                        <div class="modal-dialog" role="document">
                            <div class="modal-content">
                                <div class="modal-header">
                                    <h5 class="modal-title" id="updateAssignmentDataLabel">Update User Data</h5>
                                    <button type="button" class="close" data-dismiss="modal" aria-label="Close">
                                      <span aria-hidden="true">&times;</span>
                                <div class="modal-body">
                                    <form#updateAssignment enctype=#{enc}>
                                        ^{form}
                                        <div.form-group>
                                            <input.btn.btn-primary type=submit value="update">
                    |]    

uploadAssignmentForm classes = renderBootstrap3 BootstrapBasicForm $ (,,,,)
            <$> fileAFormReq (bfs ("Assignment" :: Text))
            <*> areq (selectFieldList classnames) (bfs ("Class" :: Text)) Nothing
            <*> aopt (jqueryDayField def) (bfs ("Due Date"::Text)) Nothing
            <*> aopt textareaField (bfs ("Assignment Description"::Text)) Nothing
            <*> lift (liftIO getCurrentTime)
    where classnames = map (\theclass -> (courseTitle . entityVal $ theclass, theclass)) classes

updateAssignmentForm = renderBootstrap3 BootstrapBasicForm $ (,,)
            <$> areq fileName "" Nothing
            <*> aopt (jqueryDayField def) (bfs ("Due Date"::Text)) Nothing
            <*> aopt textareaField (bfs ("Assignment Description"::Text)) Nothing
    where fileName :: (Monad m, RenderMessage (HandlerSite m) FormMessage) => Field m Text 
          fileName = hiddenField

setBookAssignmentForm classes = renderBootstrap3 BootstrapBasicForm $ (,,)
            <$> areq (selectFieldList classnames) (bfs ("Class" :: Text)) Nothing
            <*> areq (selectFieldList chapters) (bfs ("Problem Set" :: Text))  Nothing
            <*> areq (jqueryDayField def) (bfs ("Due Date"::Text)) Nothing
    where chapters = map (\x -> ("Problem Set " ++ pack (show x),x)) [1..15 ] :: [(Text,Int)]
          classnames = map (\theclass -> (courseTitle . entityVal $ theclass, theclass)) classes

createCourseForm = renderBootstrap3 BootstrapBasicForm $ (,,,)
            <$> areq textField (bfs ("Title" :: Text)) Nothing
            <*> aopt textareaField (bfs ("Course Description"::Text)) Nothing
            <*> areq (jqueryDayField def) (bfs ("Start Date"::Text)) Nothing
            <*> areq (jqueryDayField def) (bfs ("End Date"::Text)) Nothing

saveAssignment file = do
        let assignmentname = unpack $ fileName file
        path <- assignmentPath assignmentname
        liftIO $ fileMove file path

classWidget :: Entity Course -> HandlerT App IO Widget
classWidget classent = do
       let cid = entityKey classent
           course = entityVal classent
           mprobs = decode . fromStrict . courseTextbookProblems $ course :: Maybe (IntMap UTCTime)
       allUserData <- map entityVal <$> (runDB $ selectList [UserDataEnrolledIn ==. Just cid] [])
       asmd <- runDB $ selectList [AssignmentMetadataCourse ==. cid] []
       let allUids = (map userDataUserId  allUserData)
       musers <- mapM (\x -> runDB (get x)) allUids
       let users = catMaybes musers
       allScores <- mapM (scoreByIdAndClass cid) allUids >>= return . zip (map userIdent users)
       let usersAndData = zip users allUserData
       (Just course) <- runDB $ get cid
       return [whamlet|
                    <h2>Assignments
                    <table.table.table-striped>
                        <thead>
                            <th> Assignment
                            <th> Due Date
                        <tbody>
                            $maybe probs <- mprobs
                                $forall (set,due) <- Data.IntMap.toList probs
                                    <tr>
                                        <td>Problem Set #{show set}
                                        <td>#{show due}
                        $forall a <- map entityVal asmd
                            <tr>
                                <td>
                                    <a href=@{AssignmentR $ assignmentMetadataFilename a}>
                                        #{assignmentMetadataFilename a}
                                $maybe due <- assignmentMetadataDuedate a
                                    <td>#{show due}
                                $nothing
                                    <td>No Due Date
                    <h2>Students
                    <table.table.table-striped>
                        <thead>
                            <th> Registered Student
                            <th> Student Name
                            <th> Total Score
                        <tbody>
                            $forall (u,UserData fn ln _ _ _) <- usersAndData
                                <tr>
                                    <td>
                                        <a href=@{UserR (userIdent u)}>#{userIdent u}
                                    <td>
                                        #{ln}, #{fn}
                                    <td>
                                        #{tryLookup allScores (userIdent u)}/#{show $ courseTotalPoints course}
              |]
    where tryLookup l x = case lookup x l of
                          Just n -> show n
                          Nothing -> "can't find scores"
          

-- TODO compare directory contents with database results
listAssignmentMetadata theclass = do asmd <- runDB $ selectList [AssignmentMetadataCourse ==. theclass] []
                                     return asmd

assignmentPath f = do dir <- assignmentDir
                      return $ dir </> f

assignmentDir = do master <- getYesod 
                   if appDevel (appSettings master) 
                        then return "assignments"
                        else return "/root/assignments"
