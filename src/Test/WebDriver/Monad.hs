{-# LANGUAGE FlexibleContexts, TypeFamilies, GeneralizedNewtypeDeriving,
             MultiParamTypeClasses, CPP, UndecidableInstances #-}
module Test.WebDriver.Monad
       ( WD(..), runWD, runSession, finallyClose, closeOnException, getSessionHistory, dumpSessionHistory
       ) where

import Test.WebDriver.Class
import Test.WebDriver.Session
import Test.WebDriver.Config
import Test.WebDriver.Commands
import Test.WebDriver.Internal

import Control.Monad.Base (MonadBase, liftBase)
import Control.Monad.Reader
import Control.Monad.Trans.Control (MonadBaseControl(..), StM)
import Control.Monad.State.Strict (StateT, evalStateT, get, put)
--import Control.Monad.IO.Class (MonadIO)
import Control.Exception.Lifted
import Control.Monad.Catch (MonadThrow, MonadCatch)
import Control.Applicative


{- |A state monad for WebDriver commands.
-}
newtype WD a = WD (StateT WDSession IO a)
  deriving (Functor, Applicative, Monad, MonadIO, MonadThrow, MonadCatch)

instance MonadBase IO WD where
  liftBase = WD . liftBase

instance MonadBaseControl IO WD where
#if MIN_VERSION_monad_control(1,0,0)
  type StM WD a = StM (StateT WDSession IO) a

  liftBaseWith f = WD $
    liftBaseWith $ \runInBase ->
    f (\(WD sT) -> runInBase $ sT)

  restoreM = WD . restoreM
#else
  data StM WD a = StWD {unStWD :: StM (StateT WDSession IO) a}

  liftBaseWith f = WD $
    liftBaseWith $ \runInBase ->
    f (\(WD sT) -> liftM StWD . runInBase $ sT)

  restoreM = WD . restoreM . unStWD
#endif

instance WDSessionState WD where
  getSession = WD get
  putSession = WD . put

instance WebDriver WD where
  doCommand headers method path args =
    mkRequest headers method path args
    >>= sendHTTPRequest
    >>= either throwIO return
    >>= getJSONResult
    >>= either throwIO return

-- |Executes a 'WD' computation within the 'IO' monad, using the given
-- 'WDSession' as state for WebDriver requests.
runWD :: WDSession -> WD a -> IO a
runWD sess (WD wd) = evalStateT wd sess

-- |Executes a 'WD' computation within the 'IO' monad, automatically creating a new session beforehand.
--
-- NOTE: session is not automatically closed when complete. If you want this behavior, use 'finallyClose'.
-- Example:
-- >    runSessionThenClose action = runSession myConfig . finallyClose $ action
runSession :: WDConfig -> WD a -> IO a
runSession conf wd = do
  sess <- mkSession conf
  runWD sess $ createSession (wdRequestHeaders conf) (wdCapabilities conf) >> wd

-- |A finalizer ensuring that the session is always closed at the end of
-- the given 'WD' action, regardless of any exceptions.
finallyClose:: WebDriver wd => wd a -> wd a
finallyClose wd = closeOnException wd <* closeSession

-- |Exception handler that closes the session when an
-- asynchronous exception is thrown, but otherwise leaves the session open
-- if the action was successful.
closeOnException :: WebDriver wd => wd a -> wd a
closeOnException wd = wd `onException` closeSession

-- |Gets the command history for the current session.
getSessionHistory :: WDSessionState wd => wd [SessionHistory]
getSessionHistory = fmap wdSessHist getSession 

-- |Prints a history of API requests to stdout after computing the given action.
dumpSessionHistory :: (MonadIO wd, WebDriver wd) => wd a -> wd a
dumpSessionHistory = (`finally` (getSession >>= liftIO . print . wdSessHist))
