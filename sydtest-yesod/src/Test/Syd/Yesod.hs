{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}

module Test.Syd.Yesod
  ( -- * Functions to run a test suite
    yesodSpec,
    yesodSpecWithSiteGenerator,
    yesodSpecWithSiteGeneratorAndArgument,
    yesodSpecWithSiteSupplier,
    yesodSpecWithSiteSupplierWith,

    -- ** Core
    YesodSpec,
    YesodClient (..),
    YesodClientM (..),
    runYesodClientM,
    YesodExample,

    -- ** Helper functions in case you want to do something fancy
    yesodSpecWithFunc,

    -- * Helper functions to define tests
    yit,
    ydescribe,

    -- * Making requests
    get,
    post,
    performMethod,
    performRequest,

    -- ** Using the request builder
    request,
    setUrl,
    setMethod,
    addRequestHeader,
    addPostParam,
    RequestBuilder (..),
    runRequestBuilder,
    getLocation,

    -- *** Token
    addToken,
    addToken_,
    addTokenFromCookie,
    addTokenFromCookieNamedToHeaderNamed,

    -- * Declaring assertions
    statusIs,

    -- ** Reexports
    module HTTP,
  )
where

import qualified Blaze.ByteString.Builder as Builder
import Control.Monad.Catch
import Control.Monad.Reader
import Control.Monad.State (MonadState, StateT (..), evalStateT, execStateT)
import qualified Control.Monad.State as State
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as SB8
import qualified Data.ByteString.Lazy as LB
import qualified Data.ByteString.Lazy.Char8 as LB8
import Data.CaseInsensitive (CI)
import qualified Data.CaseInsensitive as CI
import Data.Map (Map)
import qualified Data.Map as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Stack
import Network.HTTP.Client as HTTP
import qualified Network.HTTP.Client as HTTP
import Network.HTTP.Types as HTTP
import Network.Wai.Handler.Warp as Warp
import Test.Syd
import Test.Syd.Yesod.Client
import Test.Syd.Yesod.Def
import Web.Cookie as Cookie
import Yesod.Core as Yesod
import Yesod.Core.Unsafe

-- | Make a @GET@ request for the given route
get :: (Yesod site, RedirectUrl site url) => url -> YesodClientM site ()
get = performMethod methodGet

-- | Make a @POST@ request for the given route
post :: (Yesod site, RedirectUrl site url) => url -> YesodClientM site ()
post = performMethod methodPost

performMethod :: (Yesod site, RedirectUrl site url) => Method -> url -> YesodClientM site ()
performMethod method route = request $ do
  setUrl route
  setMethod method

statusIs :: HasCallStack => Int -> YesodClientM site ()
statusIs i = do
  mLastResp <- State.gets yesodClientStateLastResponse
  liftIO $ case mLastResp of
    Nothing -> expectationFailure "No request made yet."
    Just r -> statusCode (responseStatus r) `shouldBe` i

newtype RequestBuilder site a = RequestBuilder
  { unRequestBuilder ::
      StateT
        (RequestBuilderData site)
        (ReaderT (YesodClient site) IO)
        a
  }
  deriving
    ( Functor,
      Applicative,
      Monad,
      MonadIO,
      MonadReader (YesodClient site),
      MonadState (RequestBuilderData site),
      MonadFail,
      MonadThrow
    )

data RequestBuilderData site = RequestBuilderData
  { requestBuilderDataMethod :: !Method,
    requestBuilderDataUrl :: !Text,
    requestBuilderDataHeaders :: !HTTP.RequestHeaders,
    requestBuilderDataPostData :: !PostData
  }

data PostData
  = MultipleItemsPostData [RequestPart]
  | BinaryPostData ByteString

data RequestPart
  = ReqKvPart Text Text
  | ReqFilePart Text FilePath ByteString Text

initialRequestBuilderData :: RequestBuilderData site
initialRequestBuilderData =
  RequestBuilderData
    { requestBuilderDataMethod = "GET",
      requestBuilderDataUrl = "",
      requestBuilderDataHeaders = [],
      requestBuilderDataPostData = MultipleItemsPostData []
    }

runRequestBuilder :: RequestBuilder site a -> YesodClientM site Request
runRequestBuilder (RequestBuilder func) = do
  client <- ask
  p <- asks yesodClientSitePort
  RequestBuilderData {..} <-
    liftIO $
      runReaderT
        ( execStateT
            func
            initialRequestBuilderData
        )
        client
  req <- liftIO $ parseRequest $ T.unpack requestBuilderDataUrl
  pure $
    req
      { port = p,
        method = requestBuilderDataMethod,
        requestHeaders = requestBuilderDataHeaders
      }

request :: RequestBuilder site a -> YesodClientM site ()
request rb = do
  req <- runRequestBuilder rb
  performRequest req

setUrl :: (Yesod site, RedirectUrl site url) => url -> RequestBuilder site ()
setUrl route = do
  site <- asks yesodClientSite
  Right url <-
    fmap ("http://localhost" <>)
      <$> Yesod.Core.Unsafe.runFakeHandler
        M.empty
        (const $ error "Test.Syd.Yesod: No logger available")
        site
        (toTextUrl route)
  State.modify'
    ( \oldReq ->
        oldReq
          { requestBuilderDataUrl = url
          }
    )

addRequestHeader :: HTTP.Header -> RequestBuilder site ()
addRequestHeader h = State.modify' (\r -> r {requestBuilderDataHeaders = h : requestBuilderDataHeaders r})

addPostParam :: Text -> Text -> RequestBuilder site ()
addPostParam name value =
  State.modify' $ \r -> r {requestBuilderDataPostData = addPostData (requestBuilderDataPostData r)}
  where
    addPostData (BinaryPostData _) = error "Trying to add post param to binary content."
    addPostData (MultipleItemsPostData posts) =
      MultipleItemsPostData $ ReqKvPart name value : posts

addGetParam :: Text -> Text -> RequestBuilder site ()
addGetParam = undefined

-- | Look up the CSRF token from the given form data and add it to the request header
addToken_ :: HasCallStack => Query -> RequestBuilder site ()
addToken_ scope = undefined

-- | Look up the CSRF token from the only form data and add it to the request header
addToken :: HasCallStack => RequestBuilder site ()
addToken = undefined -- addToken_ ""

-- | Look up the CSRF token from the cookie with name 'defaultCsrfCookieName' and add it to the request header with name 'defaultCsrfHeaderName'.
addTokenFromCookie :: HasCallStack => RequestBuilder site ()
addTokenFromCookie = addTokenFromCookieNamedToHeaderNamed defaultCsrfCookieName defaultCsrfHeaderName

-- | Looks up the CSRF token stored in the cookie with the given name and adds it to the given request header.
addTokenFromCookieNamedToHeaderNamed ::
  HasCallStack =>
  -- | The name of the cookie
  ByteString ->
  -- | The name of the header
  CI ByteString ->
  RequestBuilder site ()
addTokenFromCookieNamedToHeaderNamed cookieName headerName = do
  cookies <- getRequestCookies
  case lookup cookieName cookies of
    Just csrfCookie -> addRequestHeader (headerName, csrfCookie)
    Nothing ->
      liftIO $
        expectationFailure $
          concat
            [ "addTokenFromCookieNamedToHeaderNamed failed to lookup CSRF cookie with name: ",
              show cookieName,
              ". Cookies were: ",
              show cookies
            ]

setMethod :: Method -> RequestBuilder site ()
setMethod m = State.modify' (\r -> r {requestBuilderDataMethod = m})

performRequest :: Request -> YesodClientM site ()
performRequest req = do
  man <- asks yesodClientManager
  resp <- liftIO $ httpLbs req man
  State.modify' (\s -> s {yesodClientStateLastResponse = Just resp})

getRequestCookies :: RequestBuilder site Cookies
getRequestCookies = undefined

-- | Query the last response using CSS selectors, returns a list of matched fragments
htmlQuery :: HasCallStack => Query -> YesodExample site [LB.ByteString]
htmlQuery = undefined

-- -- | Query the last response using CSS selectors, returns a list of matched fragments
-- htmlQuery' ::
--   HasCallStack =>
--   (state -> Maybe (Response LB.ByteString)) ->
--   [Text] ->
--   Query ->
--   SIO state [HtmlLBS]
-- htmlQuery' getter errTrace query = withResponse' getter ("Tried to invoke htmlQuery' in order to read HTML of a previous response." : errTrace) $ \res ->
--   case findBySelector (simpleBody res) query of
--     Left err -> failure $ query <> " did not parse: " <> T.pack (show err)
--     Right matches -> return $ map (encodeUtf8 . TL.pack) matches

-- | Use HXT to parse a value from an HTML tag.
-- Check for usage examples in this module's source.
-- parseHTML :: HtmlLBS -> Cursor
-- parseHTML html = fromDocument $ HD.parseLBS html