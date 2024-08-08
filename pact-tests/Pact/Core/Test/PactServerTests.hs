{-# LANGUAGE TypeApplications #-}

-- |

module Pact.Core.Test.PactServerTests where

import Control.Monad.IO.Class
import qualified Data.Aeson as A
import qualified Data.List.NonEmpty as NE
import Data.Proxy
import Data.Text
import Data.Text.Encoding
import qualified Network.HTTP.Types   as HTTP
--import Pact.Core.Builtin
--import Pact.Core.ChainData
import Pact.Core.Command.Client
import Pact.Core.Command.Crypto
import Pact.Core.Command.RPC
import Pact.Core.Command.Server
--import Pact.Core.Command.Server.Servant
import Pact.Core.Command.Types
--import Pact.Core.Compile
--import Pact.Core.Environment.Types
import Pact.Core.Errors
import Pact.Core.Evaluate
--import Pact.Core.Gas
import Pact.Core.Hash
--import Pact.Core.Info
import Pact.Core.PactValue
--import Pact.Core.Persistence.Types
--import Pact.Core.SPV
import qualified Pact.JSON.Encode as J
import Servant.API
import Servant.Client
import Servant.Server
import Test.Tasty
import Test.Tasty.Wai
import qualified Test.Tasty.HUnit as HUnit
import qualified Data.ByteString.Lazy as LBS
import Pact.Core.StableEncoding
import Data.Default
import Pact.Core.ChainData


sendClient :: SubmitBatch -> ClientM RequestKeys
pollClient :: PollRequest -> ClientM PollResponses
listenClient :: ListenRequest -> ClientM ListenResponse
localClient :: Command Text -> ClientM (CommandResult Log (PactErrorCode Info))
sendClient :<|> pollClient :<|> listenClient :<|> localClient = client (Proxy @API)

tests :: IO TestTree
tests =  do
  env <- defaultEnv
  pure $ testGroup "PactServer"
    [ t404 env
    , sendTests env
    , listenTests env
    , integrationTests env
    ]
  where
  testCase env = testWai (serve (Proxy @API) (server env))
  t404 env = testCase env "non-existing endpoint gives 404" $ do
    r404 <- get "/does/not/exists/"
    assertStatus 404 r404
  sendTests env = testGroup "send endpoint"
    [ testCase env "unsupported media type (no header set)" $ do
        res <- post "/api/v1/send" mempty
        assertStatus 415 res
    , testCase env "unsupported media type (wrong media type)" $ do
        res <- postWithHeaders "/api/v1/send" mempty [(HTTP.hContentType, "text/html; charset=utf-8")]
        assertStatus 415 res
    , testCase env "accept valid request" $ do
        serializedCmd <- liftIO mkSubmitBatch
        res <- postWithHeaders "/api/v1/send" serializedCmd [(HTTP.hContentType, "application/json")]
        assertStatus 200 res
    ]
  listenTests env = testGroup "listen endpoint"
    [ testCase env "non existing request key results in 404" $ do
        -- hash with pactHashLength (32) size
        let h = Hash "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            req = J.encode $ J.build $ ListenRequest (RequestKey h)
        res <- postWithHeaders "/api/v1/listen" req  [(HTTP.hContentType, "application/json")]
        assertStatus 404 res

    , testCase env "request with invalid request key results in 400" $ do
        let h = Hash ""
            req = J.encode $ J.build $ ListenRequest (RequestKey h)
        res <- postWithHeaders "/api/v1/listen" req  [(HTTP.hContentType, "application/json")]
        assertStatus 400 res
    ]
  integrationTests env = testGroup "integration test"
    [ testCase env "send and listen request" $ do
        cmd <- liftIO mkSubmitBatch
        res@(SResponse _ _ reqResp) <- postWithHeaders "/api/v1/send" cmd [(HTTP.hContentType, "application/json")]
        assertStatus 200 res

        let (Just (RequestKeys rks)) :: Maybe RequestKeys = A.decodeStrict $ LBS.toStrict reqResp
        assertBool "Response contains one request key" (NE.length rks == 1)

        let req = J.encode $ J.build $ ListenRequest (NE.head rks)

        res'@(SResponse _ _ reqResp') <- postWithHeaders "/api/v1/listen" req  [(HTTP.hContentType, "application/json")]
        assertStatus 200 res'

        let (Just cmdResult) :: Maybe (CommandResult Log (PactErrorCode Info)) = A.decodeStrict $ LBS.toStrict reqResp'
        assertEqual "Result match expected output" (PactResultOk $ PInteger 3) (_crResult cmdResult)
    ]

assertBool :: String -> Bool -> Session ()
assertBool msg c = liftIO (HUnit.assertBool msg c)

assertEqual :: (Eq a , Show a)=> String -> a -> a -> Session ()
assertEqual msg a b = liftIO (HUnit.assertEqual msg a b)

mkSubmitBatch :: IO LBS.ByteString
mkSubmitBatch = do
  ks <- generateEd25519KeyPair
  let rpc :: PactRPC Text = Exec (ExecMsg "(+ 1 2)" PUnit)
      metaData = J.build $ StableEncoding (def :: PublicMeta)
  cmd <- mkCommand [(ks, [])] [] metaData "nonce" Nothing rpc
  pure $ J.encode $ J.build $ SubmitBatch $ fmap decodeUtf8 cmd NE.:| []
