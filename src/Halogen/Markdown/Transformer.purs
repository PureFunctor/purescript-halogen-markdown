module Halogen.Markdown.Transformer where

import Prelude

import Control.Monad.Free (Free, liftF, runFreeM)
import Control.Monad.Reader.Trans (ReaderT, ask, runReaderT)
import Control.Monad.Rec.Class (class MonadRec, Step(..), tailRecM)
import Data.Array as Array
import Data.Either (Either(..))
import Data.List (List(..), (:))
import Data.List as List
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Class (class MonadEffect, liftEffect)
import Effect.Ref (Ref, modify_, new, read)
import Effect.Unsafe (unsafePerformEffect)
import Halogen.HTML as HH
import Halogen.Markdown.AST (Markdown(..), toHeader)
import Halogen.Markdown.Parser (parseMarkdown)


data TransformerF n
  = ToHalogen Markdown n
  | NextLine (Maybe Markdown → n)
  | PushStack Markdown n
  | PopStack (Maybe Markdown → n)
  | PeekStack (Maybe Markdown → n)
  | FlushResult (List Element → n)

derive instance functorTransformerF ∷ Functor TransformerF


type TransformerM = Free TransformerF


toHalogen ∷ Markdown → TransformerM Unit
toHalogen = liftF <<< flip ToHalogen unit


nextLine ∷ TransformerM (Maybe Markdown)
nextLine = liftF $ NextLine identity


pushStack ∷ Markdown → TransformerM Unit
pushStack = liftF <<< flip PushStack unit


popStack ∷ TransformerM (Maybe Markdown)
popStack = liftF $ PopStack identity


peekStack ∷ TransformerM (Maybe Markdown)
peekStack = liftF $ PeekStack identity


flushResult ∷ TransformerM (List Element)
flushResult = liftF $ FlushResult identity


data Element = Element (∀ w a. HH.HTML w a)


type MachineEnv =
  { lines ∷ Ref (List Markdown)
  , stack ∷ Ref (List Markdown)
  , elems ∷ Ref (List Element)
  }


type MachineT = ReaderT MachineEnv


runMachineT ∷
  ∀ m r
  . MonadEffect m
  ⇒ MachineT m r
  → MachineEnv
  → m r
runMachineT = runReaderT


runTransformerM ∷
  ∀ m r
  . MonadEffect m
  ⇒ MonadRec m
  ⇒ TransformerM r
  → List Markdown
  → m r
runTransformerM dsl mds = do
  env <- liftEffect do
    lines <- new mds
    stack <- new Nil
    elems <- new Nil
    pure { lines, stack, elems }
  runMachineT (runFreeM go dsl) env
  where
    go ∷ TransformerF (TransformerM r) → MachineT m (TransformerM r)
    go instruction = do
      env <- ask

      liftEffect $ case instruction of
        ToHalogen e n -> do
          elems <- read env.elems

          case e of
            Text text ->
              pushHalogen ( HH.p [ ] [ HH.text text ] )
            Heading level text ->
              pushHalogen ( (toHeader level) [ ] [ HH.text text ] )
            BlankLine ->
              pure unit

          pure n
          where
            pushHalogen ∷ (∀ w a. HH.HTML w a) → Effect Unit
            pushHalogen element =
              modify_ ( Cons ( Element element ) ) env.elems

        NextLine f -> do
          lines <- read env.lines

          case List.head lines of
            Just e -> do
              modify_ (List.drop 1) env.lines
              pure (f $ Just e)
            Nothing ->
              pure $ f Nothing

        PushStack e n ->
          modify_ (\es -> e : es) env.stack *> pure n

        PopStack f -> liftEffect do
          stack <- read env.stack

          case List.head stack of
            Just e -> do
              modify_ (List.drop 1) env.stack
              pure (f $ Just e)
            Nothing ->
              pure $ f Nothing

        PeekStack f -> do
          stack <- read env.stack
          pure $ f $ List.head stack

        FlushResult f -> do
          elems <- read env.elems
          pure $ f elems


mkHTML ∷ forall w a. String → Array (HH.HTML w a)
mkHTML markdown = unsafePerformEffect $ do
  case parseMarkdown markdown of
    Right markdown' -> do
      elements <- runTransformerM go markdown'
      pure $ (\(Element e) -> e) <$> Array.fromFoldable elements
    _ -> pure []
  where
    go = (tailRecM normalize unit) *> (tailRecM transform unit)

    normalize _ = do
      mLine <- nextLine

      case mLine of

        Just line@(Text text) -> do
          mTop <- peekStack
          line' <- case mTop of
            Just (Text text') -> do
              _ <- popStack
              pure $ Text $ text <> "\n" <> text
            _ ->
              pure line
          pushStack line'
          pure (Loop unit)

        Just line -> do
          pushStack line
          pure (Loop unit)

        Nothing -> do
          pure (Done unit)

    transform _ = do
      mLine <- popStack

      case mLine of

        Just line -> do
          toHalogen line
          pure (Loop unit)

        Nothing -> do
          result <- flushResult
          pure (Done result)
