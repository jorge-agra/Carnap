module Handler.Register (getRegisterR, getRegisterEnrollR, getEnrollR, postEnrollR, postRegisterR, postRegisterEnrollR) where

import Import
import Yesod.Form.Bootstrap3
import Text.Blaze.Html (toMarkup)
import Util.Database

getRegister :: ([Entity Course] -> UserId -> Html -> MForm Handler (FormResult (Maybe UserData), Widget)) -> Route App
    -> Text -> Handler Html
getRegister theform theaction ident = do
    userId <- fromIdent ident
    time <- liftIO getCurrentTime
    courseEntities <- runDB $ selectList [CourseStartDate <. time, CourseEndDate >. time] []
    (widget,enctype) <- generateFormPost (theform courseEntities userId)
    defaultLayout $ do
        setTitle "Carnap - Registration"
        $(widgetFile "register")

postRegister :: ([Entity Course] -> UserId -> Html -> MForm Handler (FormResult (Maybe UserData), Widget))
    -> Text -> Handler Html
postRegister theform ident = do
        userId <- fromIdent ident
        time <- liftIO getCurrentTime
        courseEntities <- runDB $ selectList [CourseStartDate <. time, CourseEndDate >. time] []
        ((result, _), _) <- runFormPost (theform courseEntities userId)
        case result of
            FormSuccess (Just userdata) ->
                do msuccess <- tryInsert userdata
                   case msuccess of
                        Just _ -> deleteSession "enrolling-in" >> redirect (UserR ident)
                        Nothing -> defaultLayout clashPage
            FormSuccess Nothing ->
                do setMessage "Class not found - link may be incorrect or expired. Please enroll manually."
                   redirect (RegisterR ident)
            _ -> defaultLayout errorPage

    where errorPage = [whamlet|
                        <div.container>
                            <p> Looks like something went wrong with that form
                            <p>
                                <a href=@{RegisterR ident}>Try again?
                      |]
          clashPage = [whamlet|
                        <div.container>
                            <p> Looks like you're already registered.
                            <p>
                                <a href=@{UserR ident}>Go to your user page?
                      |]

getRegisterR :: Text -> Handler Html
getRegisterR ident = getRegister (registrationForm ident) (RegisterR ident) ident

getEnrollR :: Text -> Handler Html
getEnrollR classname = do setSession "enrolling-in" classname
                          Entity uid user <- requireAuth
                          mclass <- runDB $ getBy (UniqueCourse classname)
                          mud <- runDB $ getBy $ UniqueUserData uid
                          case mud of
                              Nothing -> redirect (RegisterEnrollR classname (userIdent user))
                              Just (Entity _ ud) -> case (mclass, userDataEnrolledIn ud) of
                                  (Just (Entity cid _), Just ecid) | cid == ecid -> redirect HomeR --redirect those who try to reenroll in a closed course that they belong to
                                  (Just (Entity cid course ), _) | not (courseEnrollmentOpen course) -> permissionDenied $ "Enrollment is closed for " <> courseTitle course <> "."
                                  (Just (Entity cid course), Just _) -> defaultLayout (reenrollPage course user)
                                  (Just (Entity _ course), Nothing) -> defaultLayout (confirm course)
                                  (Nothing,_) -> setMessage "no course with that title" >> notFound
    where reenrollPage course user = [whamlet|
                           <div.container>
                               <h2>It looks like you're already enrolled.
                               <p>Do you want to change your enrollment and join #{courseTitle course}?
                               <p>Changing your enrollment will not cause you to lose any saved work.  You can rejoin your previous class by changing your enrollment settings at the bottom of your #
                                  <a href=@{UserR (userIdent user)}>user page#
                                  .
                               <p>
                                   <form action="" method="post">
                                       <button name="change-enrollment" value="change">
                                            Change Enrollment
                         |]
          confirm course = [whamlet|
                                   <div.container>
                                       <p>Do you want to join #{courseTitle course}?
                                       <p>
                                           <form action="" method="post">
                                               <button name="change-enrollment" value="change">
                                                    Join #{courseTitle course}
                                |]

postEnrollR :: Text -> Handler Html
postEnrollR classname = do (Entity uid _) <- requireAuth
                           (mclass, mudent) <- runDB $ (,) <$> getBy (UniqueCourse classname)
                                                           <*> getBy (UniqueUserData uid)
                           case (mclass, mudent) of
                               (Nothing,_) -> setMessage "no course with that title" >> notFound
                               (_,Nothing) -> setMessage "no user data (do you need to register?)" >> notFound
                               (Just (Entity _ course), _) 
                                    | not (courseEnrollmentOpen course) -> permissionDenied $ "Enrollment is closed for " <> courseTitle course <> "."
                               (Just (Entity cid _), Just (Entity udid _)) -> do
                                    runDB $ update udid [UserDataEnrolledIn =. Just cid]
                                    setMessage $ "Enrollment change complete"
                                    redirect HomeR

--registration with enrollment built into the path
getRegisterEnrollR :: Text -> Text -> Handler Html
getRegisterEnrollR classname ident = do
        mclass <- runDB $ getBy (UniqueCourse classname)
        case mclass of
            Nothing -> setMessage "no course with that title" >> notFound
            Just (Entity _ course) 
                | not (courseEnrollmentOpen course) -> setMessage ("Enrollment for " <> toMarkup (courseTitle course) <> "is closed.") >> redirect (RegisterR ident)
            _ -> getRegister (enrollmentForm classname ident) (RegisterEnrollR classname ident) ident

postRegisterR :: Text -> Handler Html
postRegisterR ident = postRegister (registrationForm ident) ident

postRegisterEnrollR :: Text -> Text -> Handler Html
postRegisterEnrollR theclass ident = postRegister (enrollmentForm theclass ident) ident

registrationForm :: Text -> [Entity Course] -> UserId -> Html -> MForm Handler (FormResult (Maybe UserData), Widget)
registrationForm ident courseEntities userId = do
        renderBootstrap3 BootstrapBasicForm $ fixedId userId ident
            <$> areq textField "First name " Nothing
            <*> areq textField "Last name " Nothing
            <*> areq (selectFieldList courses) "enrolled in " Nothing
    where openCourseEntities = filter (\(Entity k v) -> courseEnrollmentOpen v) courseEntities
          courses = ("No Course", Nothing) : map (\(Entity k v) -> (courseTitle v, Just k)) openCourseEntities

fixedId :: Key User -> Text -> Text -> Text -> Maybe (Key Course) -> Maybe UserData
fixedId userId ident fname lname ckey = Just $ UserData 
                { userDataFirstName = fname
                , userDataEmail = Just ident
                , userDataLastName = lname
                , userDataEnrolledIn = ckey
                , userDataInstructorId = Nothing
                , userDataIsAdmin = False
                , userDataUserId = userId
                }

enrollmentForm :: Text -> Text -> [Entity Course] -> UserId ->  Html -> MForm Handler (FormResult (Maybe UserData), Widget)
enrollmentForm classtitle ident courseEntities userId = do
        renderBootstrap3 BootstrapBasicForm $ fixedId'
            <$> areq textField "First name " Nothing
            <*> areq textField "Last name " Nothing
    where fixedId' fname lname = fixedId userId ident fname lname course
          course = case filter (\e -> classtitle == courseTitle (entityVal e)) courseEntities of
                     [] -> Nothing
                     e:_ -> Just $ entityKey e
