{-# LANGUAGE OverloadedStrings #-}

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class

import qualified Data.ByteString.Char8 as BC8
import qualified Data.ByteString.Lazy as BL
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe)
import Data.Monoid (mappend, mconcat)
import qualified Data.Text as TS
import qualified Data.Text.Lazy as T
import qualified Data.Text.Encoding as TE

import Network.HTTP.Types.Status
import Network.Wai
import Network.Wai.Middleware.RequestLogger
import Network.Wai.Middleware.Gzip
import Network.Whois
import qualified Network.Socket as S

import Graphics.ImageMagick.MagickWand

import qualified Text.Blaze.Html5 as H
import Text.Blaze.Html5.Attributes
import Text.Blaze.Html.Renderer.Text (renderHtml)

import Web.Scotty

safe :: ActionM a -> ActionM (Maybe a)
safe = (`rescue` const (return Nothing)) . (Just `fmap`)

paramMay :: (Parsable a) => T.Text -> ActionM (Maybe a)
paramMay = safe . param

isTextUseragent :: Maybe String -> Bool
isTextUseragent (Just a) = any (`isInfixOf` a) textUAs
  where
    textUAs = ["Wget"
             , "curl"
             , "libcurl"
             , "Supybot"
             , "Ruby"
             , "NetBSD-ftp"
             , "HTTPie"
             , "OpenBSD ftp"
             , "haskell-HTTP"
             ]
isTextUseragent Nothing = False

prepareResponse :: T.Text -> ActionM ()
prepareResponse a = do
  agent <- reqHeader "User-Agent"
  if isTextUseragent $ T.unpack <$> agent
           then text a
           else html $ renderHtml $
             H.html $
               H.body $
                 H.pre $ H.toHtml a

main = scotty 3000 $ do
  middleware $ gzip $ def { gzipFiles = GzipCompress }
  middleware logStdoutDev

  get "/ip" $ do
    ip <- fmap (T.pack . show . remoteHost) request
    prepareResponse ip

  get "/ua" $ do
    agent <- reqHeader "User-Agent"
    maybe (raise "User-Agent header not found!") prepareResponse agent

  get "/w/:query" $ do
    query <- param "query"
    x <- liftIO $ whois query
    prepareResponse $ T.pack . unlines $ fmap (fromMaybe "") x

  get "/status/:code/:message" $ do
    code <- param "code"
    message <- param "message"
    status $ Status code message

  get "/et/:item" $ do
    item <- param "item"
    qs <- fmap (T.fromStrict . TE.decodeUtf8 . rawQueryString) request
    redirect $ "http://www.etsy.com/listing/" `mappend` item `mappend` qs

  get (regex "^/image/([0-9]+)[x*]([0-9]+)\\.([[:alnum:]]+)$") $ do
    width <- param "1"
    height <- param "2"
    extension <- param "3" :: ActionM String
    bgColor <- paramMay "bgcolor"
    text <- paramMay "text"

    img <- liftIO $ withMagickWandGenesis $ do
      (_,w) <- magickWand
      (_,dw) <- drawingWand
      c <- pixelWand
      c `setColor` BC8.append (BC8.pack "#") (fromMaybe "333333" bgColor)
      newImage w width height c
      -- Texty stuff.
      c `setColor` "white"
      dw `setFillColor` c
      dw `setTextAntialias` True
      dw `setStrokeOpacity` 0

      let m = fromMaybe (show width ++ "x" ++ show height) text
      drawAnnotation dw 65 65 (TS.pack m)

      -- Do housekeeping and return the image.
      drawImage w dw
      w `setImageFormat` TS.pack extension
      getImageBlob w

    mime <- liftIO $ withMagickWandGenesis $ toMime (TS.pack extension)
    setHeader "Content-Type" (T.fromStrict mime)
    raw $ BL.fromStrict img
