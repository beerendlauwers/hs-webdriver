{-# LANGUAGE GeneralizedNewtypeDeriving, DeriveDataTypeable,
    TemplateHaskell, OverloadedStrings, ExistentialQuantification, 
    MultiParamTypeClasses, TypeFamilies, NoMonoLocalBinds #-}
{-# OPTIONS_HADDOCK not-home #-}
module Test.WebDriver.Types 
       ( -- * WebDriver sessions
         WD(..), WDSession(..), defaultSession, SessionId(..)
         -- * Capabilities and configuration
       , Capabilities(..), defaultCaps, allCaps
       , Platform(..), ProxyType(..)
         -- ** Browser-specific configuration
       , Browser(..), firefox, chrome, ie, opera, iPhone, iPad, android
         -- * WebDriver objects and command-specific types
       , Element(..)
       , WindowHandle(..), currentWindow
       , Selector(..)
       , JSArg(..)
       , FocusSelector(..)
       , Cookie(..), mkCookie
       , Orientation(..)
       , MouseButton(..)
         -- * Exceptions
       , InvalidURL(..), NoSessionId(..), BadJSON(..)
       , HTTPStatusUnknown(..), HTTPConnError(..)
       , UnknownCommand(..), ServerError(..)
       , FailedCommand(..), FailedCommandType(..)
       , FailedCommandInfo(..), StackFrame(..)
       , mkFailedCommandInfo, failedCommand
       ) where

import Test.WebDriver.Firefox.Profile
import Test.WebDriver.Chrome.Extension

import Data.Aeson
import Data.Aeson.TH
import Data.Aeson.Types
import Network.Stream (ConnError)


import Data.Text as Text (toLower, toUpper)
import Data.Text (Text)
import Data.ByteString (ByteString)

import Control.Exception.Lifted
import Data.Typeable
import Control.Applicative
import Control.Monad.State.Strict
import Control.Monad.Base
import Control.Monad.Trans.Control
import Data.Word
import Data.String
import Data.Default
import qualified Data.Char as C


{- |A monadic interface to the WebDriver server. This monad is a simple, strict 
wrapper over 'IO', threading session information between sequential commands
-}
newtype WD a = WD (StateT WDSession IO a)
  deriving (Functor, Monad, MonadState WDSession, MonadIO
           ,Applicative)

instance MonadBase IO WD where
  liftBase = WD . liftBase

instance MonadBaseControl IO WD where
  data StM WD a = StWD {unStWD :: StM (StateT WDSession IO) a}
  
  liftBaseWith f = WD $  
    liftBaseWith $ \runInBase ->
    f (\(WD sT) -> liftM StWD . runInBase $ sT)

  restoreM = WD . restoreM . unStWD

{- |An opaque identifier for a WebDriver session. These handles are produced by 
the server on session creation, and act to identify a session in progress. -} 
newtype SessionId = SessionId Text
                  deriving (Eq, Ord, Show, Read, 
                            FromJSON, ToJSON)


{- |An opaque identifier for a browser window -}
newtype WindowHandle = WindowHandle Text
                     deriving (Eq, Ord, Show, Read, 
                               FromJSON, ToJSON)
{- |An opaque identifier for a web page element. -}
newtype Element = Element Text
                  deriving (Eq, Ord, Show, Read)

-- |A special 'WindowHandle' that always refers to the currently focused window.
currentWindow :: WindowHandle
currentWindow = WindowHandle "current"

-- |Specifies a window or frame to focus on.
data FocusSelector = -- |focus on a window
                     OnWindow WindowHandle
                     -- |focus on a frame by 0-based index
                   | OnFrameIndex Integer       
                     -- |focus on a frame by name or ID
                   | OnFrameName Text
                     -- |focus on a frame Element
                   | OnFrameElement Element
                     -- |focus on the first frame, or the main document
                     -- if iframes are used.
                   | DefaultFrame
                   deriving (Eq, Show, Read)

{- |Information about a WebDriver session. This structure is passed
implicitly through all 'WD' computations, and is also used to configure the 'WD'
monad before execution. -}
data WDSession = WDSession { 
                             -- |Host name of the WebDriver server for this 
                             -- session
                             wdHost   :: String
                             -- |Port number of the server
                           , wdPort   :: Word16
                             -- |An opaque reference identifying the session.
                             -- A value of Nothing indicates that a session 
                             -- hasn't been created yet. To create new sessions,
                             -- use the 'Test.WebDriver.Commands.createSession' 
                             -- and 'Test.WebDriver.runSession' functions.
                           , wdSessId :: Maybe SessionId 
                           } deriving (Eq, Show)

instance Default WDSession where
  def = WDSession { wdHost   = "127.0.0.1"
                  , wdPort   = 4444
                  , wdSessId = Nothing
                  }

{- |A default session connects to localhost on port 4444, and hasn't been 
created yet. This value is the same as 'def' but with a more specific type. -}
defaultSession :: WDSession
defaultSession = def


{- |A structure describing the capabilities of a session. This record
serves dual roles. 

* It's used to specify the desired capabilities for a session before
it's created. In this usage, fields that are set to Nothing indicate
that we have no preference for that capability.

* When returned by 'Test.WebDriver.Commands.getCaps', it's used to
describe the actual capabilities given to us by the WebDriver
server. Here a value of Nothing indicates that the server doesn't
support the capability. Thus, for Maybe Bool fields, both Nothing and
Just False indicate a lack of support for the desired capability.
-}
data Capabilities = Capabilities { -- |Browser choice and browser specific 
                                   -- settings.
                                   browser                  :: Browser
                                   -- |Browser version to use.
                                 , version                  :: Maybe String
                                   -- |Platform on which the browser should/will
                                   -- run.   
                                 , platform                 :: Platform
                                   -- |Proxy configuration.
                                 , proxy                    :: ProxyType
                                 , javascriptEnabled        :: Maybe Bool
                                 , takesScreenshot          :: Maybe Bool
                                 , handlesAlerts            :: Maybe Bool
                                 , databaseEnabled          :: Maybe Bool
                                 , locationContextEnabled   :: Maybe Bool
                                 , applicationCacheEnabled  :: Maybe Bool
                                 , browserConnectionEnabled :: Maybe Bool
                                 , cssSelectorsEnabled      :: Maybe Bool
                                 , webStorageEnabled        :: Maybe Bool
                                 , rotatable                :: Maybe Bool
                                 , acceptSSLCerts           :: Maybe Bool
                                 , nativeEvents             :: Maybe Bool
                                 } deriving (Eq, Show)

instance Default Capabilities where
  def = Capabilities { browser = firefox
                     , version = Nothing
                     , platform = Any
                     , javascriptEnabled = Nothing
                     , takesScreenshot = Nothing
                     , handlesAlerts = Nothing
                     , databaseEnabled = Nothing
                     , locationContextEnabled = Nothing
                     , applicationCacheEnabled = Nothing
                     , browserConnectionEnabled = Nothing
                     , cssSelectorsEnabled = Nothing
                     , webStorageEnabled = Nothing
                     , rotatable = Nothing
                     , acceptSSLCerts = Nothing
                     , nativeEvents = Nothing
                     , proxy = UseSystemSettings
                     }

-- |Default capabilities. This is the same as the 'Default' instance, but with 
-- a more specific type. By default we use Firefox of an unspecified version 
-- with default settings on whatever platform is available. 
-- All Maybe Bool capabilities are set to Nothing (no preference).
defaultCaps :: Capabilities
defaultCaps = def

-- |Same as 'defaultCaps', but with all Maybe Bool capabilities set to 
-- Just True.
allCaps :: Capabilities
allCaps = defaultCaps { javascriptEnabled = Just True
                      , takesScreenshot = Just True
                      , handlesAlerts = Just True
                      , databaseEnabled = Just True
                      , locationContextEnabled = Just True
                      , applicationCacheEnabled = Just True
                      , browserConnectionEnabled = Just True
                      , cssSelectorsEnabled = Just True
                      , webStorageEnabled = Just True
                      , rotatable = Just True
                      , acceptSSLCerts = Just True
                      , nativeEvents = Just True
                      }
      

-- |Browser setting and browser-specific capabilities.
data Browser = Firefox { -- |The firefox profile to use. If Nothing, a
                         -- a default temporary profile is automatically created
                         -- and used.
                         ffProfile :: Maybe PreparedFirefoxProfile
                         -- |Firefox logging preference
                       , ffLogPref :: Maybe FFLogPref
                         -- |Path to Firefox binary. If Nothing, use a sensible
                         -- system-based default.
                       , ffBinary :: Maybe FilePath
                       }
             | Chrome { chromeDriverVersion :: Maybe String 
                        -- |Path to Chrome binary. If Nothing, use a sensible
                        -- system-based default.
                      , chromeBinary :: Maybe FilePath
                        -- |A list of command-line options to pass to the 
                        -- Chrome binary.
                      , chromeOptions :: [String]
                        -- |A list of extensions to use.
                      , chromeExtensions :: [ChromeExtension]
                      } 
             | IE { ignoreProtectedModeSettings :: Bool
                  --, useLegacyInternalServer     :: Bool
                  }
             | Opera -- ^ Opera-specific configuration coming soon!
             | HTMLUnit
             | IPhone 
             | IPad
             | Android
             deriving (Eq, Show)

-- |Default Firefox settings. All fields are set to Nothing.
firefox :: Browser
firefox = Firefox Nothing Nothing Nothing

-- |Default Chrome settings. All Maybe fields are set to Nothing, no options are
-- specified, and no extensions are used.
chrome :: Browser
chrome = Chrome Nothing Nothing [] []

-- |Default IE settings. 'ignoreProtectedModeSettings' is set to True.
ie :: Browser
ie = IE True

opera :: Browser
opera = Opera

--safari :: Browser
--safari = Safari

htmlUnit :: Browser
htmlUnit = HTMLUnit

iPhone :: Browser
iPhone = IPhone

iPad :: Browser
iPad = IPad

android :: Browser
android = Android


-- |Represents platform options supported by WebDriver. The value Any represents
-- no preference.
data Platform = Windows | XP | Vista | Mac | Linux | Unix | Any
              deriving (Eq, Show, Ord, Bounded, Enum)

-- |Available settings for the proxy 'Capabilities' field
data ProxyType = NoProxy 
               | UseSystemSettings
               | AutoDetect
                 -- |Use a proxy auto-config file specified by URL
               | PAC { autoConfigUrl :: String }
                 -- |Manually specify proxy hosts as hostname:port strings.
                 -- Note that behavior is undefined for empty strings.
               | Manual { ftpProxy  :: String
                        , sslProxy  :: String
                        , httpProxy :: String
                        }
               deriving (Eq, Show)


-- |For Firefox sessions; indicates Firefox's log level
data FFLogPref = LogOff | LogSevere | LogWarning | LogInfo | LogConfig 
             | LogFine | LogFiner | LogFinest | LogAll
             deriving (Eq, Show, Ord, Bounded, Enum)


instance Exception InvalidURL
-- |An invalid URL was given
newtype InvalidURL = InvalidURL String 
                deriving (Eq, Show, Typeable)

instance Exception NoSessionId
-- |A command requiring a session ID was attempted when no session ID was 
-- available.
newtype NoSessionId = NoSessionId String 
                 deriving (Eq, Show, Typeable)

instance Exception BadJSON
-- |An error occured when parsing a JSON value.
newtype BadJSON = BadJSON String 
             deriving (Eq, Show, Typeable)

instance Exception HTTPStatusUnknown
-- |An unexpected HTTP status was sent by the server.
data HTTPStatusUnknown = HTTPStatusUnknown (Int, Int, Int) String
                       deriving (Eq, Show, Typeable)

instance Exception HTTPConnError
-- |HTTP connection errors.
newtype HTTPConnError = HTTPConnError ConnError
                     deriving (Eq, Show, Typeable)

instance Exception UnknownCommand
-- |A command was sent to the WebDriver server that it didn't recognize.
newtype UnknownCommand = UnknownCommand String 
                    deriving (Eq, Show, Typeable)

instance Exception ServerError
-- |A server-side exception occured
newtype ServerError = ServerError String
                      deriving (Eq, Show, Typeable)

instance Exception FailedCommand
-- |This exception encapsulates many different kinds of exceptions that can
-- occur when a command fails. 
data FailedCommand = FailedCommand FailedCommandType FailedCommandInfo
                   deriving (Eq, Show, Typeable)

-- |The type of failed command exception that occured.
data FailedCommandType = NoSuchElement
                       | NoSuchFrame
                       | UnknownFrame
                       | StaleElementReference
                       | ElementNotVisible
                       | InvalidElementState
                       | UnknownError
                       | ElementIsNotSelectable
                       | JavascriptError
                       | XPathLookupError
                       | Timeout
                       | NoSuchWindow
                       | InvalidCookieDomain
                       | UnableToSetCookie
                       | UnexpectedAlertOpen
                       | NoAlertOpen
                       | ScriptTimeout
                       | InvalidElementCoordinates
                       | IMENotAvailable
                       | IMEEngineActivationFailed
                       | InvalidSelector
                       | MoveTargetOutOfBounds
                       | InvalidXPathSelector
                       | InvalidXPathSelectorReturnType
                       | MethodNotAllowed
                       deriving (Eq, Ord, Enum, Bounded, Show)

-- |Detailed information about the failed command provided by the server.
data FailedCommandInfo = FailedCommandInfo { errMsg    :: String
                                           , errSessId :: Maybe SessionId 
                                           , errScreen :: Maybe ByteString
                                           , errClass  :: Maybe String
                                           , errStack  :: [StackFrame]
                                           }
                       deriving (Eq)


-- |Constructs a FailedCommandInfo from only an error message.
mkFailedCommandInfo :: String -> FailedCommandInfo
mkFailedCommandInfo m = FailedCommandInfo {errMsg = m
                                          , errSessId = Nothing
                                          , errScreen = Nothing
                                          , errClass  = Nothing
                                          , errStack  = []
                                          }

-- |Convenience function to throw a 'FailedCommand' locally with no server-side 
-- info present.
failedCommand :: FailedCommandType -> String -> WD a
failedCommand t m = throwIO . FailedCommand t =<< getCmdInfo
  where getCmdInfo = do
          sessId <- wdSessId <$> get
          return $ (mkFailedCommandInfo m) { errSessId = sessId }

-- |An individual stack frame from the stack trace provided by the server 
-- during a FailedCommand.
data StackFrame = StackFrame { sfFileName   :: String
                             , sfClassName  :: String
                             , sfMethodName :: String
                             , sfLineNumber :: Word
                             }
                deriving (Show, Eq)

-- |Cookies are delicious delicacies.
data Cookie = Cookie { cookName   :: Text
                     , cookValue  :: Text
                     , cookPath   :: Maybe Text
                     , cookDomain :: Maybe Text
                     , cookSecure :: Maybe Bool
                     , cookExpiry :: Maybe Integer
                     } deriving (Eq, Show)              

-- |Creates a Cookie with only a name and value specified. All other
-- fields are set to Nothing, which tells the server to use default values.
mkCookie :: Text -> Text -> Cookie
mkCookie name value = Cookie { cookName = name, cookValue = value,
                               cookPath = Nothing, cookDomain = Nothing,
                               cookSecure = Nothing, cookExpiry = Nothing
                             }

-- |Specifies element(s) within a DOM tree using various selection methods.
data Selector = ById Text  
              | ByName Text
              | ByClass Text -- ^ (Note: multiple classes are not  
                             -- allowed. For more control, use ByCSS)
              | ByTag Text            
              | ByLinkText Text       
              | ByPartialLinkText Text
              | ByCSS Text
              | ByXPath Text
              deriving (Eq, Show, Ord)

-- |An existential wrapper for any 'ToJSON' instance. This allows us to pass
-- parameters of many different types to Javascript code.
data JSArg = forall a. ToJSON a => JSArg a

-- |A screen orientation
data Orientation = Landscape | Portrait
                 deriving (Eq, Show, Ord, Bounded, Enum)

-- |A mouse button
data MouseButton = LeftButton | MiddleButton | RightButton
                 deriving (Eq, Show, Ord, Bounded, Enum)



instance Show FailedCommandInfo where --todo: pretty print
  show i =   showString "{errMsg = "     . shows (errMsg i) 
           . showString ", errSessId = " . shows (errSessId i)
           . showString ", errScreen = " . screen
           . showString ", errClass = "  . shows (errClass i)
           . showString ", errStack = "  . shows (errStack i) 
           $ "}"
    where screen = showString $ case errScreen i of 
                                  Just _  -> "Just \"...\""
                                  Nothing -> "Nothing"
            

instance FromJSON Element where
  parseJSON (Object o) = Element <$> o .: "ELEMENT"
  parseJSON v = typeMismatch "Element" v
  
instance ToJSON Element where
  toJSON (Element e) = object ["ELEMENT" .= e]


instance ToJSON Capabilities where
  toJSON c = object $ [ "browserName" .= browser'
                      , f version "version"
                      , f platform "platform"
                      , f proxy "proxy"
                      , f javascriptEnabled "javascriptEnabled"
                      , f takesScreenshot "takesScreenshot"
                      , f handlesAlerts "handlesAlerts"
                      , f databaseEnabled "databaseEnabled"
                      , f locationContextEnabled "locationContextEnabled"
                      , f applicationCacheEnabled "applicationCacheEnabled"
                      , f browserConnectionEnabled "browserConnectionEnabled"
                      , f cssSelectorsEnabled "cssSelectorsEnabled"
                      , f webStorageEnabled "webStorableEnabled"
                      , f rotatable "rotatable"
                      , f acceptSSLCerts "acceptSslCerts"
                      , f nativeEvents "nativeEvents"
                      ]
                      ++ browserInfo
    where 
      browser' = browser c
      browserInfo = case browser' of
        Firefox {ffProfile = prof, ffLogPref = pref, ffBinary = bin }
          -> ["firefox_profile" .= prof
             ,"loggingPrefs" .= pref
             ,"firefox_binary" .= bin
             ]
        Chrome {chromeDriverVersion = v, chromeBinary = b, 
                chromeOptions = o, chromeExtensions = e}
          -> ["chrome.chromedriverVersion" .= v
             ,"chrome.binary" .= b
             ,"chrome.switches" .= o
             ,"chrome.extensions" .= e
             ]       
        IE {ignoreProtectedModeSettings = i{-, useLegacyInternalServer = u-}}
          -> ["IgnoreProtectedModeSettings" .= i
             --,"useLegacyInternalServer" .= u
             ]
        _ -> []
      f :: ToJSON a => (Capabilities -> a) -> Text -> Pair
      f field key = key .= field c

instance FromJSON Capabilities where  
  parseJSON (Object o) = Capabilities <$> req "browserName"
                                      <*> opt "version" Nothing
                                      <*> req "platform"
                                      <*> opt "proxy" NoProxy
                                      <*> b "javascriptEnabled"
                                      <*> b "takesScreenshot"
                                      <*> b "handlesAlerts"
                                      <*> b "databaseEnabled"
                                      <*> b "locationContextEnabled"
                                      <*> b "applicationCacheEnabled"
                                      <*> b "browserConnectionEnabled"
                                      <*> b "cssSelectorEnabled"
                                      <*> b "webStorageEnabled"
                                      <*> b "rotatable"
                                      <*> b "acceptSslCerts"
                                      <*> b "nativeEvents"
    where req :: FromJSON a => Text -> Parser a
          req = (o .:)            -- required field
          opt :: FromJSON a => Text -> a -> Parser a
          opt k d = o .:? k .!= d -- optional field
          b :: Text -> Parser (Maybe Bool)
          b k = opt k Nothing     -- Maybe Bool field
  parseJSON v = typeMismatch "Capabilities" v

instance FromJSON FailedCommandInfo where
  parseJSON (Object o) = 
    FailedCommandInfo <$> (req "message" >>= maybe (return "") return)
                      <*> pure Nothing
                      <*> opt "screen"     Nothing
                      <*> opt "class"      Nothing
                      <*> opt "stackTrace" []
    where --req :: FromJSON a => Text -> Parser a 
          req = (o .:)            --required key
          --opt :: FromJSON a => Text -> a -> Parser a
          opt k d = o .:? k .!= d --optional key
  parseJSON v = typeMismatch "FailedCommandInfo" v

instance FromJSON StackFrame where
  parseJSON (Object o) = StackFrame <$> reqStr "fileName"
                                    <*> reqStr "className"
                                    <*> reqStr "methodName"
                                    <*> req    "lineNumber"
    where req :: FromJSON a => Text -> Parser a
          req = (o .:) -- all keys are required
          reqStr :: Text -> Parser String
          reqStr k = req k >>= maybe (return "") return
  parseJSON v = typeMismatch "StackFrame" v

$( deriveToJSON (map C.toLower . drop 4) ''Cookie )

$( deriveJSON (map C.toUpper . drop 3) ''FFLogPref )

instance FromJSON Cookie where
  parseJSON (Object o) = Cookie <$> req "name"
                                <*> req "value"
                                <*> opt "path" Nothing
                                <*> opt "domain" Nothing
                                <*> opt "secure" Nothing
                                <*> opt "expiry" Nothing
    where 
      req :: FromJSON a => Text -> Parser a
      req = (o .:)
      opt :: FromJSON a => Text -> a -> Parser a
      opt k d = o .:? k .!= d
  parseJSON v = typeMismatch "Cookie" v


instance ToJSON Browser where
  toJSON Firefox {} = String "firefox"
  toJSON b = String . f . toLower . fromString . show $ b
    where f "ie" = "internet explorer"
          f  x   = x

instance FromJSON Browser where
  parseJSON (String jStr) = case toLower jStr of
    "firefox"           -> return firefox
    "chrome"            -> return chrome
    "internet explorer" -> return ie
    "opera"             -> return opera
    -- "safari"            -> return safari
    "iphone"            -> return iPhone
    "ipad"              -> return iPad
    "android"           -> return android
    "htmlunit"          -> return htmlUnit
    err  -> fail $ "Invalid Browser string " ++ show err
  parseJSON v = typeMismatch "Browser" v

instance ToJSON Platform where
  toJSON = String . toUpper . fromString . show

instance FromJSON Platform where
  parseJSON (String jStr) = case toLower jStr of
    "windows" -> return Windows
    "xp"      -> return XP
    "vista"   -> return Vista
    "mac"     -> return Mac
    "linux"   -> return Linux
    "unix"    -> return Unix 
    "any"     -> return Any
    err -> fail $ "Invalid Platform string " ++ show err 
  parseJSON v = typeMismatch "Platform" v

instance ToJSON Orientation where
  toJSON = String . toUpper . fromString . show

instance FromJSON Orientation where
  parseJSON (String jStr) = case toLower jStr of
    "landscape" -> return Landscape
    "portrait"  -> return Portrait
    err         -> fail $ "Invalid Orientation string " ++ show err
  parseJSON v = typeMismatch "Orientation" v
  
instance ToJSON MouseButton where
  toJSON = String . toUpper . fromString . show
  
instance FromJSON MouseButton where
  parseJSON (String jStr) = case toLower jStr of
    "left"   -> return LeftButton
    "middle" -> return MiddleButton
    "right"  -> return RightButton
    err      -> fail $ "Invalid MouseButton string " ++ show err
  parseJSON v = typeMismatch "MouseButton" v


instance FromJSON ProxyType where
  parseJSON (Object obj) = do
    let f :: FromJSON a => Text -> Parser a 
        f = (obj .:)
    pTyp <- f "proxyType"
    case toLower pTyp of
      "direct" -> return NoProxy
      "system" -> return UseSystemSettings
      "pac"    -> PAC <$> f "autoConfigUrl"
      "manual" -> Manual <$> f "ftpProxy" 
                         <*> f "sslProxy"
                         <*> f "httpProxy"
      _ -> fail $ "Invalid ProxyType " ++ show pTyp
  parseJSON v = typeMismatch "ProxyType" v
      
instance ToJSON ProxyType where
  toJSON pt = object $ case pt of
    NoProxy -> 
      ["proxyType" .= ("DIRECT" :: String)]
    UseSystemSettings -> 
      ["proxyType" .= ("SYSTEM" :: String)]
    AutoDetect ->
      ["proxyType" .= ("AUTODETECT" :: String)]
    PAC{autoConfigUrl = url} -> 
      ["proxyType" .= ("PAC" :: String)
      ,"autoConfigUrl" .= url
      ]
    Manual{ftpProxy = ftp, sslProxy = ssl, httpProxy = http} ->
      ["proxyType" .= ("MANUAL" :: String)
      ,"ftpProxy"  .= ftp
      ,"sslProxy"  .= ssl
      ,"httpProxy" .= http
      ]

instance ToJSON Selector where
  toJSON s = case s of
    ById t              -> selector "id" t
    ByName t            -> selector "name" t
    ByClass t           -> selector "class name" t
    ByTag t             -> selector "tag name" t
    ByLinkText t        -> selector "link text" t
    ByPartialLinkText t -> selector "partial link text" t
    ByCSS t             -> selector "css selector" t
    ByXPath t           -> selector "xpath" t
    where
      selector :: Text -> Text -> Value
      selector sn t = object ["using" .= sn, "value" .= t]
      
instance ToJSON JSArg where
  toJSON (JSArg a) = toJSON a

instance ToJSON FocusSelector where
  toJSON s = case s of
    OnWindow w -> toJSON w
    OnFrameIndex i -> toJSON i
    OnFrameName n -> toJSON n
    OnFrameElement e -> toJSON e