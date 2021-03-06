module Simple.Ajax
  ( simpleRequest, simpleRequest_
  , SimpleRequest, SimpleRequestRow
  , postR, post, postR_, post_
  , putR, put, putR_, put_
  , deleteR, delete, deleteR_, delete_
  , patchR, patch, patchR_, patch_
  , getR, get
  , handleResponse, handleResponse_
  , module Simple.Ajax.Errors
  ) where

import Prelude

import Affjax (Request, Response, RetryPolicy, URL, defaultRequest, request, retry)
import Affjax.RequestBody (RequestBody)
import Affjax.RequestBody as RequestBody
import Affjax.RequestHeader (RequestHeader(..))
import Affjax.ResponseFormat (ResponseFormat)
import Affjax.ResponseFormat as ResponseFormat
import Data.Bifunctor (lmap)
import Data.Either (Either(..))
import Data.HTTP.Method (CustomMethod, Method(..))
import Data.Maybe (Maybe(..))
import Data.MediaType (MediaType(..))
import Data.Variant (expand, inj)
import Effect.Aff (Aff, Error, try)
import Foreign (Foreign)
import Prim.Row as Row
import Record as Record
import Simple.Ajax.Errors (HTTPError, AjaxError, _parseError, _badRequest, _unAuthorized,
                           _forbidden, _notFound, _methodNotAllowed, _formatError, _serverError,
                           mapBasicError, parseError, statusOk)
import Simple.JSON (class ReadForeign, class WriteForeign, readJSON, writeJSON)
import Type.Prelude (SProxy(..))

handleResponse ::
  forall b.
  ReadForeign b =>
  Either Error (Response (Either ResponseFormat.ResponseFormatError String)) ->
  Either AjaxError b
handleResponse res = case res of
  Left e -> Left $ inj _serverError $ show e
  Right response ->
    case response.body of
      Left (ResponseFormat.ResponseFormatError err _) -> Left $ inj _formatError err
      Right j
        | statusOk response.status -> lmap (expand <<< parseError) (readJSON j)
        | otherwise -> Left $ expand $ mapBasicError response.status j

handleResponse_ ::
  Either Error (Response (Either ResponseFormat.ResponseFormatError String)) ->
  Either HTTPError Unit
handleResponse_ res = case res of
  Left e -> Left $ inj _serverError $ show e
  Right response -> case response.body of
      Left (ResponseFormat.ResponseFormatError err _) -> Left $ inj _formatError err
      Right j
        | statusOk response.status -> Right unit
        | otherwise -> Left $ expand $ mapBasicError response.status j

-- | Writes the contest as JSON.
writeContent ::
  forall a.
  WriteForeign a =>
  Maybe a ->
  Maybe RequestBody
writeContent a = RequestBody.string <<< writeJSON <$> a

-- | An utility method to build requests.
defaults ::
  forall rall rsub rx.
  Row.Union rsub rall rx =>
  Row.Nub rx rall =>
  { | rall } ->
  { | rsub } ->
  { | rall }
defaults = flip Record.merge

-- | The rows of a `Request a`
type RequestRow a = ( method          :: Either Method CustomMethod
                    , url             :: URL
                    , headers         :: Array RequestHeader
                    , content         :: Maybe RequestBody
                    , username        :: Maybe String
                    , password        :: Maybe String
                    , withCredentials :: Boolean
                    , responseFormat  :: ResponseFormat a
                    , retryPolicy     :: Maybe RetryPolicy
                    )

type SimpleRequestRow = ( headers         :: Array RequestHeader
                        , username        :: Maybe String
                        , password        :: Maybe String
                        , withCredentials :: Boolean
                        , retryPolicy     :: Maybe RetryPolicy
                        )

-- | A Request object with only the allowed fields.
type SimpleRequest = Record SimpleRequestRow


defaultSimpleRequest :: Record (RequestRow String)
defaultSimpleRequest = Record.merge { responseFormat : ResponseFormat.string
                                    , headers : [ Accept (MediaType "application/json") ]
                                    , retryPolicy : Nothing
                                    } defaultRequest

toReq :: Record (RequestRow String) -> Request String
toReq = Record.delete (SProxy :: SProxy "retryPolicy")

-- | Takes a subset of a `SimpleRequest` and uses it to
-- | override the fields of the defaultRequest
buildRequest ::
  forall r rx t.
  Row.Union r SimpleRequestRow rx =>
  Row.Union r (RequestRow String) t =>
  Row.Nub rx SimpleRequestRow =>
  Row.Nub t (RequestRow String) =>
  { | r } ->
  Record (RequestRow String)
buildRequest = defaults defaultSimpleRequest

-- | Makes an HTTP request and tries to parse the response json.
-- |
-- | Helper methods are provided for the most common requests.
simpleRequest ::
  forall a b r rx t.
  WriteForeign a =>
  ReadForeign b =>
  Row.Union r SimpleRequestRow rx =>
  Row.Union r (RequestRow String) t =>
  Row.Nub rx SimpleRequestRow =>
  Row.Nub t (RequestRow String) =>
  Either Method CustomMethod ->
  { | r } ->
  URL ->
  Maybe a ->
  Aff (Either AjaxError b)
simpleRequest method r url content = do
  let req = (buildRequest r) { method = method
                             , url = url
                             , content = writeContent content
                             }
  res <- case req.retryPolicy of
    Nothing -> try $ request $ toReq req
    Just p -> try $ retry p request $ toReq req
  pure $ handleResponse res

-- | Makes an HTTP request ignoring the response payload.
-- |
-- | Helper methods are provided for the most common requests.
simpleRequest_ ::
  forall a r rx t.
  WriteForeign a =>
  Row.Union r SimpleRequestRow rx =>
  Row.Union r (RequestRow String) t =>
  Row.Nub rx SimpleRequestRow =>
  Row.Nub t (RequestRow String) =>
  Either Method CustomMethod ->
  { | r } ->
  URL ->
  Maybe a ->
  Aff (Either HTTPError Unit)
simpleRequest_ method r url content = do
  let req = (buildRequest r) { method = method
                             , url = url
                             , content = writeContent content
                             }
  res <- case req.retryPolicy of
    Nothing -> try $ request $ toReq req
    Just p -> try $ retry p request $ toReq req
  pure $ handleResponse_ res

-- | Makes a `GET` request, taking a subset of a `SimpleRequest` and an `URL` as arguments
-- | and then tries to parse the response json.
getR ::
  forall b r rx t.
  ReadForeign b =>
  Row.Union r SimpleRequestRow rx =>
  Row.Union r (RequestRow String) t =>
  Row.Nub rx SimpleRequestRow =>
  Row.Nub t (RequestRow String) =>
  { | r } ->
  URL ->
  Aff (Either AjaxError b)
getR r url = do
  let req = (buildRequest r) { method = Left GET
                             , url = url
                             , responseFormat = ResponseFormat.string
                             }
  res <- case req.retryPolicy of
    Nothing -> try $ request $ toReq req
    Just p -> try $ retry p request $ toReq req
  pure $ handleResponse res

-- | Makes a `GET` request, taking an `URL` as argument
-- | and then tries to parse the response json.
get ::
  forall b.
  ReadForeign b =>
  URL ->
  Aff (Either AjaxError b)
get = getR {} -- defaultSimpleRequest

-- | Makes a `POST` request, taking a subset of a `SimpleRequest`, an `URL` and an optional payload
-- | and then tries to parse the response json.
postR :: forall a b r rx t.
  WriteForeign a =>
  ReadForeign b =>
  Row.Union r SimpleRequestRow rx =>
  Row.Union r (RequestRow String) t =>
  Row.Nub rx SimpleRequestRow =>
  Row.Nub t (RequestRow String) =>
  { | r } ->
  URL ->
  Maybe a ->
  Aff (Either AjaxError b)
postR = simpleRequest (Left POST)

-- | Makes a `POST` request, taking an `URL` and an optional payload
-- | trying to parse the response json.
post ::
  forall a b.
  WriteForeign a =>
  ReadForeign b =>
  URL ->
  Maybe a ->
  Aff (Either AjaxError b)
post = postR {}

-- | Makes a `POST` request, taking a subset of a `SimpleRequest`, an `URL` and an optional payload,
-- | ignoring the response payload.
postR_ ::
  forall a r rx t.
  WriteForeign a =>
  Row.Union r SimpleRequestRow rx =>
  Row.Union r (RequestRow String) t =>
  Row.Nub rx SimpleRequestRow =>
  Row.Nub t (RequestRow String) =>
  { | r } ->
  URL ->
  Maybe a ->
  Aff (Either HTTPError Unit)
postR_ = simpleRequest_ (Left POST)

-- | Makes a `POST` request, taking an `URL` and an optional payload,
-- | ignoring the response payload.
post_ ::
  forall a.
  WriteForeign a =>
  URL ->
  Maybe a ->
  Aff (Either HTTPError Unit)
post_ = postR_ {}

-- | Makes a `PUT` request, taking a subset of a `SimpleRequest`, an `URL` and an optional payload
-- | and then tries to parse the response json.
putR :: forall a b r rx t.
  WriteForeign a =>
  ReadForeign b =>
  Row.Union r SimpleRequestRow rx =>
  Row.Union r (RequestRow String) t =>
  Row.Nub rx SimpleRequestRow =>
  Row.Nub t (RequestRow String) =>
  { | r } ->
  URL ->
  Maybe a ->
  Aff (Either AjaxError b)
putR = simpleRequest (Left PUT)

-- | Makes a `PUT` request, taking an `URL` and an optional payload
-- | trying to parse the response json.
put ::
  forall a b.
  WriteForeign a =>
  ReadForeign b =>
  URL ->
  Maybe a ->
  Aff (Either AjaxError b)
put = putR {}

-- | Makes a `PUT` request, taking a subset of a `SimpleRequest`, an `URL` and an optional payload,
-- | ignoring the response payload.
putR_ ::
  forall a r rx t.
  WriteForeign a =>
  Row.Union r SimpleRequestRow rx =>
  Row.Union r (RequestRow String) t =>
  Row.Nub rx SimpleRequestRow =>
  Row.Nub t (RequestRow String) =>
  { | r } ->
  URL ->
  Maybe a ->
  Aff (Either HTTPError Unit)
putR_ = simpleRequest_ (Left PUT)

-- | Makes a `PUT` request, taking an `URL` and an optional payload,
-- | ignoring the response payload.
put_ ::
  forall a.
  WriteForeign a =>
  URL ->
  Maybe a ->
  Aff (Either HTTPError Unit)
put_ = putR_ {}

-- | Makes a `PATCH` request, taking a subset of a `SimpleRequest`, an `URL` and an optional payload
-- | and then tries to parse the response json.
patchR :: forall a b r rx t.
  WriteForeign a =>
  ReadForeign b =>
  Row.Union r SimpleRequestRow rx =>
  Row.Union r (RequestRow String) t =>
  Row.Nub rx SimpleRequestRow =>
  Row.Nub t (RequestRow String) =>
  { | r } ->
  URL ->
  Maybe a ->
  Aff (Either AjaxError b)
patchR = simpleRequest (Left PATCH)

-- | Makes a `PATCH` request, taking an `URL` and an optional payload
-- | trying to parse the response json.
patch ::
  forall a b.
  WriteForeign a =>
  ReadForeign b =>
  URL ->
  Maybe a ->
  Aff (Either AjaxError b)
patch = patchR {}

-- | Makes a `PATCH` request, taking a subset of a `SimpleRequest`, an `URL` and an optional payload,
-- | ignoring the response payload.
patchR_ ::
  forall a r rx t.
  WriteForeign a =>
  Row.Union r SimpleRequestRow rx =>
  Row.Union r (RequestRow String) t =>
  Row.Nub rx SimpleRequestRow =>
  Row.Nub t (RequestRow String) =>
  { | r } ->
  URL ->
  Maybe a ->
  Aff (Either HTTPError Unit)
patchR_ = simpleRequest_ (Left PATCH)

-- | Makes a `PATCH` request, taking an `URL` and an optional payload,
-- | ignoring the response payload.
patch_ ::
  forall a.
  WriteForeign a =>
  URL ->
  Maybe a ->
  Aff (Either HTTPError Unit)
patch_ = patchR_ {}

-- | Makes a `DELETE` request, taking a subset of a `SimpleRequest` and an `URL`
-- | and then tries to parse the response json.
deleteR :: forall b r rx t.
  ReadForeign b =>
  Row.Union r SimpleRequestRow rx =>
  Row.Union r (RequestRow String) t =>
  Row.Nub rx SimpleRequestRow =>
  Row.Nub t (RequestRow String) =>
  { | r } ->
  URL ->
  Aff (Either AjaxError b)
deleteR req url = simpleRequest (Left DELETE) req url (Nothing :: Maybe Foreign)

-- | Makes a `DELETE` request, taking an `URL`
-- | and then tries to parse the response json.
delete ::
  forall b.
  ReadForeign b =>
  URL ->
  Aff (Either AjaxError b)
delete = deleteR {}

-- | Makes a `DELETE` request, taking a subset of a `SimpleRequest` and an `URL`,
-- | ignoring the response payload.
deleteR_ ::
  forall r rx t.
  Row.Union r SimpleRequestRow rx =>
  Row.Union r (RequestRow String) t =>
  Row.Nub rx SimpleRequestRow =>
  Row.Nub t (RequestRow String) =>
  { | r } ->
  URL ->
  Aff (Either HTTPError Unit)
deleteR_ req url = simpleRequest_ (Left DELETE) req url (Nothing :: Maybe Foreign)

-- | Makes a `DELETE` request, taking an `URL`,
-- | ignoring the response payload.
delete_ ::
  URL ->
  Aff (Either HTTPError Unit)
delete_ = deleteR_ {}
