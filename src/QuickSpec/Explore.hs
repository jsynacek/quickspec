{-# OPTIONS_HADDOCK hide #-}
{-# LANGUAGE FlexibleContexts #-}
module QuickSpec.Explore where

import QuickSpec.Explore.Polymorphic
import QuickSpec.Testing
import QuickSpec.Pruning
import QuickSpec.Term
import QuickSpec.Type
import QuickSpec.Utils
import QuickSpec.Prop
import QuickSpec.Terminal
import Control.Monad
import Control.Monad.Trans.Class
import Control.Monad.Trans.State.Strict
import Text.Printf
import Data.Semigroup(Semigroup(..))

newtype Enumerator a = Enumerator { enumerate :: Int -> [[a]] -> [a] }

-- N.B. order matters!
-- Later enumerators get to see terms which were generated by earlier ones.
instance Semigroup (Enumerator a) where
  e1 <> e2 = Enumerator $ \n tss ->
    let us = enumerate e1 n tss
        vs = enumerate e2 n (appendAt n us tss)
    in us ++ vs
instance Monoid (Enumerator a) where
  mempty = Enumerator (\_ _ -> [])
  mappend = (<>)

mapEnumerator :: ([a] -> [a]) -> Enumerator a -> Enumerator a
mapEnumerator f e =
  Enumerator $ \n tss ->
    f (enumerate e n tss)

filterEnumerator :: (a -> Bool) -> Enumerator a -> Enumerator a
filterEnumerator p e =
  mapEnumerator (filter p) e

enumerateConstants :: Sized a => [a] -> Enumerator a
enumerateConstants ts = Enumerator (\n _ -> [t | t <- ts, size t == n])

enumerateApplications :: Apply a => Enumerator a
enumerateApplications = Enumerator $ \n tss ->
    [ unPoly v
    | i <- [0..n],
      t <- tss !! i,
      u <- tss !! (n-i),
      Just v <- [tryApply (poly t) (poly u)] ]

filterUniverse :: Typed f => Universe -> Enumerator (Term f) -> Enumerator (Term f)
filterUniverse univ e =
  filterEnumerator (`usefulForUniverse` univ) e

sortTerms :: Ord b => (a -> b) -> Enumerator a -> Enumerator a
sortTerms measure e =
  mapEnumerator (sortBy' measure) e

quickSpec ::
  (Ord fun, Ord norm, Sized fun, Typed fun, Ord result, Apply (Term fun), PrettyTerm fun,
  MonadPruner (Term fun) norm m, MonadTester testcase (Term fun) m, MonadTerminal m) =>
  (Prop (Term fun) -> m ()) ->
  (Term fun -> testcase -> result) ->
  Int -> Universe -> Enumerator (Term fun) -> m ()
quickSpec present eval maxSize univ enum = do
  let
    state0 = initialState univ (\t -> size t <= 5) eval

    loop m n _ | m > n = return ()
    loop m n tss = do
      putStatus (printf "enumerating terms of size %d" m)
      let
        ts = enumerate (filterUniverse univ enum) m tss
        total = length ts
        consider (i, t) = do
          putStatus (printf "testing terms of size %d: %d/%d" m i total)
          res <- explore t
          putStatus (printf "testing terms of size %d: %d/%d" m i total)
          lift $ mapM_ present (result_props res)
          case res of
            Accepted _ -> return True
            Rejected _ -> return False
      us <- map snd <$> filterM consider (zip [1 :: Int ..] ts)
      clearStatus
      loop (m+1) n (appendAt m us tss)

  evalStateT (loop 0 maxSize (repeat [])) state0

pPrintSignature :: (Pretty a, Typed a) => [a] -> Doc
pPrintSignature funs =
  text "== Functions ==" $$
  vcat (map pPrintDecl decls)
  where
    decls = [ (prettyShow f, pPrintType (typ f)) | f <- funs ]
    maxWidth = maximum (0:map (length . fst) decls)
    pad xs = nest (maxWidth - length xs) (text xs)
    pPrintDecl (name, ty) =
      pad name <+> text "::" <+> ty
