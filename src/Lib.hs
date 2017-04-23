
module Lib where

import qualified Data.Conduit as C
import qualified Data.Conduit.List as CL
import qualified Data.Text.IO as T
import qualified Data.Text as T
import Network.HTTP -- (getResponseBody, postRequestWithBody, getRequest, simpleHTTP, urlEncode)
import Text.JSON (encode)
import Text.JSON.Yocto
import Web.Twitter.Conduit (stream, statusesFilterByTrack)
import Control.Lens.Action -- ((^!), act)
import Data.Map ((!), Map)
import Data.List (isInfixOf, or)
import Data.Conduit
import Web.Twitter.Types -- (userScreenName, statusUser, statusText, StreamingAPI(..))
import Data.List
import Data.Char

import Web.Twitter.Conduit hiding (map)
import Web.Twitter.Types.Lens hiding (userScreenName,statusUser,statusText)

import Web.Authenticate.OAuth as OA
import qualified Network.URI as URI
import Network.HTTP.Conduit
import qualified Data.Map as M
import qualified Data.ByteString.Char8 as S8
import qualified Data.CaseInsensitive as CI
import Control.Applicative
import Control.Monad.IO.Class
import Control.Monad.Base
import Control.Monad.Trans.Resource
import Control.Monad
import System.Environment
import Control.Lens
import Control.Concurrent.STM
import Control.Concurrent.STM.TMChan
import Data.Conduit.TMChan
import Data.Maybe
import Network.TCP as TCP
import GHC.Generics
import Data.Aeson (FromJSON(..), ToJSON(..), decode, withObject, (.:))
import Data.Aeson.Types
import qualified Data.ByteString.Lazy.Char8 as C
import qualified Data.Map as Map
import Data.Array ((!))
import Data.Ratio
import Data.Time.Clock
import System.CPUTime
import Control.Concurrent
import Control.Exception
import Data.Conduit.Attoparsec
import System.Process

analyze :: [String] -> IO ()
analyze politicians = do
  pr <- liftBase getProxyEnv
  (oa, cred) <- liftBase getOAuthTokens
  let twInfo = (setCredential oa cred def) {twProxy = pr}
  mgr <- newManager tlsManagerSettings
  tmChan <- newBroadcastTMChanIO :: IO (TMChan T.Text)
  chans <-
    atomically $ mapM (const (dupTMChan tmChan)) [0 .. length politicians - 1]
  forkIO $ collectTweets mgr twInfo tmChan (map T.pack politicians)
  reports <- mapM (const newEmptyMVar) [0 .. length politicians - 1]
  mapM_ (
    (\x -> forkIO (monitorPolitician x)) .
       (\i -> (politicians !! i, reports !! i, chans !! i)))
       [0 .. length politicians - 1]
  void $ loopTweets twInfo mgr reports

loopTweets ::
  TWInfo
  -> Manager
  -> [MVar (String, (Integer, Integer, Integer, Integer))]
  -> IO b
loopTweets twInfo mgr mvars = go
  where
    go = do
      results <- mapM takeMVar mvars
      -- go
      if not (null results)
        then do
          let text = concatMap (\(i,(a, b)) -> tweetText i (length results) a b) (zip [0..] results)
          sendTweet
            twInfo
            mgr
            ("Last " ++ show hours ++ " hours. " ++ text ++ "#GeneralElection")
          go
        else go

sendTweet :: TWInfo -> Manager -> String -> IO ()
sendTweet twInfo mgr text = do
  putStrLn text
  catch (Control.Monad.void (call twInfo mgr (update (T.pack text))))
    -- such as 'twitterErrorMessage = "Status is a duplicate."'
    (\ex@(TwitterErrorResponse{}) -> print ex)

hours :: Int
hours = 6

-- | in seconds.
tweetFrequency :: Int
tweetFrequency =
  let minutes = 60
      seconds = 60
  in seconds * minutes * hours

monitorPolitician ::
  (String, MVar (String, (Integer, Integer, Integer, Integer)),
   TMChan T.Text)
  -> IO b
monitorPolitician (personName, mvar, chan) = do
  let query = T.pack personName
  forever $ do
    threadDelay (tweetFrequency * 1000000)
    tweets <- atomically (consumeTweets chan)
    let relevantTweets = filter (T.isInfixOf (T.pack personName)) tweets
    analysis <- identifySentiment relevantTweets personName
    putMVar mvar (personName, analysis)

consumeTweets :: TMChan T.Text -> STM [T.Text]
consumeTweets chan = go []
  where
    go tweets = do
      x <- tryReadTMChan chan
      case x of
        Nothing -> return tweets
        Just y ->
          case y of
            Nothing -> return tweets
            Just z -> go (z : tweets)

identifySentiment :: [T.Text] -> String -> IO (Integer,Integer,Integer,Integer)
identifySentiment tweets personName = do
  sentiments <- sentiment tweets personName
  return $
    foldr
      (\a (pos, neg, neut, count) ->
         case a of
           4 -> (pos + 1, neg, neut, count + 1)
           2 -> (pos, neg, neut + 1, count + 1)
           0 -> (pos, neg + 1, neut, count + 1))
      (0, 0, 0, 0)
      sentiments

-- | runs forever in a thread, writing relevant tweets to a broadcast
-- channel for other threads to duplicate and consume from.
collectTweets :: Manager -> TWInfo -> TMChan T.Text -> [T.Text] -> IO ()
collectTweets mgr twInfo chan names = go
  where
    go = runResourceT streamAction
    streamAction = do
      src <- stream twInfo mgr (statusesFilter [Track names])
      src C.$$+- CL.map printTL =$ CL.catMaybes =$
        sinkTMChan chan False

printTL :: StreamingAPI -> Maybe T.Text
printTL (SStatus s) =
  case T.unpack (Web.Twitter.Types.userName (statusUser s)) of
    -- ignore this account's emails
    "Election Sentiment" -> Nothing
    -- a tweet of interest
    _ -> Just $ showStatus s
printTL _ = Nothing

showStatus :: AsStatus s => s -> T.Text
showStatus s = s ^. text

tweetText :: Int -> Int -> String -> (Integer, Integer, Integer, Integer) -> String
tweetText position numPositions personName (pos, neg, neutral, numTweets)
  | position == 0 = updateFirst
  | position == numPositions-1 = updateLast
  | otherwise = updateRest
  where
    updateLast  =
      show numTweets ++
      " on " ++
      personName ++
      ": " ++
      show (round positive) ++
      "%+/" ++ show (round negative) ++ "%-. "
    updateRest  =
      show numTweets ++
      " on " ++
      personName ++
      ": " ++
      show (round positive) ++
      "%+/" ++ show (round negative) ++ "%-, "
    updateFirst =
      show numTweets ++
      " tweets on " ++
      personName ++
      ": " ++
      show (round positive) ++
      "%+/" ++ show (round negative) ++ "%-, "
    positive =
      if (pos + neg) > 0
        then 100.0 * (fromInteger pos / fromInteger (pos + neg))
        else 0
    negative =
      if (pos + neg) > 0
        then 100.0 * (fromInteger neg / fromInteger (pos + neg))
        else 0

clean :: String -> String
clean str =
  let xs =
        unwords $
        filter
          (\w ->
             not
               (or
                  [ "@" `isInfixOf` w
                  , "#" `isInfixOf` w
                  , "\n" `isInfixOf` w
                  , "http://" `isInfixOf` w
                  ]))
          (words str)
  in filter (\c -> c /= '\'') xs

sentimentUrl :: String
sentimentUrl = "http://www.sentiment140.com/api/bulkClassifyJson"

runSentimentQuery :: String -> IO String
runSentimentQuery body = do
  resp <-
    simpleHTTP $
    postRequestWithBody sentimentUrl "application/json" body
  getResponseBody resp

{- process based back up.
runSentimentQuery body' = do
  let body = filter isAscii body'
  resp <- readProcess "curl"
    [ "-d"
    ,  body
    , sentimentUrl
    ]
    ""
  return resp
-}

sentiment :: [T.Text] -> String -> IO [Integer]
sentiment tweets personName =
  if null tweets
    then return []
    else do
      let body =
            "{\"data\": [" ++
            concat
              (intersperse
                 ","
                 (map
                    (\tweet ->
                       "{\"query\" : \"" ++
                       personName ++
                       "\" , \"text\": \"" ++
                       (filter (/= '\'') .
                        filter (/= '\"') . filter isAscii . clean . T.unpack)
                         tweet ++
                       ".\"}")
                    tweets)) ++
            "]}"
      respBody <- runSentimentQuery body
      if (length respBody == 0)
        then return []
        else do
          let Text.JSON.Yocto.Object jsonObjects =
                Text.JSON.Yocto.decode respBody
              Text.JSON.Yocto.Array dataArr =
                fromJust $ Map.lookup "data" jsonObjects
              elements = dataArr
              polaritys =
                map
                  (\(Text.JSON.Yocto.Object element) ->
                     fromJust $ Map.lookup "polarity" element)
                  elements
          return
            (map
               (\(Text.JSON.Yocto.Number polarity) -> numerator polarity)
               polaritys)

getOAuthTokens :: IO (OAuth, Credential)
getOAuthTokens = do
  consumerKey <- getEnv' "OAUTH_CONSUMER_KEY"
  consumerSecret <- getEnv' "OAUTH_CONSUMER_SECRET"
  accessToken <- getEnv' "OAUTH_ACCESS_TOKEN"
  accessSecret <- getEnv' "OAUTH_ACCESS_SECRET"
  let oauth =
        twitterOAuth
        {oauthConsumerKey = consumerKey, oauthConsumerSecret = consumerSecret}
      cred =
        Credential
          [(S8.pack "oauth_token", accessToken), (S8.pack "oauth_token_secret", accessSecret)]
  return (oauth, cred)
  where
    getEnv' = (S8.pack <$>) . getEnv

getProxyEnv :: IO (Maybe Proxy)
getProxyEnv = do
  env <- M.fromList . over (mapped . _1) CI.mk <$> getEnvironment
  let u =
        M.lookup (CI.mk "https_proxy") env <|> M.lookup (CI.mk "http_proxy") env <|>
        M.lookup (CI.mk "proxy") env >>=
        URI.parseURI >>=
        URI.uriAuthority
  return $
    Proxy <$> (S8.pack . URI.uriRegName <$> u) <*>
    (parsePort . URI.uriPort <$> u)
  where
    parsePort :: String -> Int
    parsePort [] = 8080
    parsePort (':':xs) = read xs
    parsePort xs = error $ "port number parse failed " ++ xs
