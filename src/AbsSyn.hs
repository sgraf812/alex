-- -----------------------------------------------------------------------------
--
-- AbsSyn.hs, part of Alex
--
-- (c) Chris Dornan 1995-2000, Simon Marlow 2003
--
-- This module provides a concrete representation for regular expressions and
-- scanners.  Scanners are used for tokenising files in preparation for parsing.
--
-- ----------------------------------------------------------------------------}

module AbsSyn (
  Code, Directive(..), Scheme(..),
  wrapperCppDefs,
  Scanner(..),
  RECtx(..),
  RExp(..), nullable,
  DFA(..), State(..), SNum, StartCode, Accept(..),
  RightContext(..), showRCtx,
  encodeStartCodes, extractActions,
  Target(..),
  UsesPreds(..), usesPreds,
  StrType(..)
  ) where

import CharSet ( CharSet, Encoding )
import Map ( Map )
import qualified Map hiding ( Map )
import Data.IntMap (IntMap)
import Sort ( nub' )
import Util ( str, nl )

import Data.Maybe ( fromJust )

infixl 4 :||
infixl 5 :%%

-- -----------------------------------------------------------------------------
-- Abstract Syntax for Alex scripts

type Code = String

data Directive
   = WrapperDirective String            -- use this wrapper
   | EncodingDirective Encoding         -- use this encoding
   | ActionType String                  -- Type signature of actions,
                                        -- with optional typeclasses
   | TypeClass String
   | TokenType String
   deriving Show

data StrType = Str | Lazy | Strict | StrictText
  deriving Eq

instance Show StrType where
  show Str = "String"
  show Lazy = "ByteString.ByteString"
  show Strict = "ByteString.ByteString"
  show StrictText = "Data.Text.Text"

data Scheme
  = Default { defaultTypeInfo :: Maybe (Maybe String, String) }
  | GScan { gscanTypeInfo :: Maybe (Maybe String, String) }
  | Basic { basicStrType :: StrType,
            basicTypeInfo :: Maybe (Maybe String, String) }
  | Posn { posnStrType :: StrType,
           posnTypeInfo :: Maybe (Maybe String, String) }
  | Monad { monadStrType :: StrType,
            monadUserState :: Bool,
            monadTypeInfo :: Maybe (Maybe String, String) }

wrapperCppDefs :: Scheme -> Maybe [String]
wrapperCppDefs Default {} = Nothing
wrapperCppDefs GScan {} = Just ["ALEX_GSCAN"]
wrapperCppDefs Basic { basicStrType = Str } = Just ["ALEX_BASIC"]
wrapperCppDefs Basic { basicStrType = Lazy } = Just ["ALEX_BASIC_BYTESTRING"]
wrapperCppDefs Basic { basicStrType = Strict } = Just ["ALEX_STRICT_BYTESTRING"]
wrapperCppDefs Basic { basicStrType = StrictText } = Just ["ALEX_STRICT_TEXT"]
wrapperCppDefs Posn { posnStrType = Str } = Just ["ALEX_POSN"]
wrapperCppDefs Posn { posnStrType = Lazy } = Just ["ALEX_POSN_BYTESTRING"]
wrapperCppDefs Posn { posnStrType = Strict } = Just ["ALEX_POSN_BYTESTRING"]
wrapperCppDefs Posn { posnStrType = StrictText } = Just ["ALEX_POSN_STRICT_TEXT"]
wrapperCppDefs Monad { monadStrType = Str,
                       monadUserState = False } = Just ["ALEX_MONAD"]
wrapperCppDefs Monad { monadStrType = Strict,
                       monadUserState = False } = Just ["ALEX_MONAD_BYTESTRING"]
wrapperCppDefs Monad { monadStrType = Lazy,
                       monadUserState = False } = Just ["ALEX_MONAD_BYTESTRING"]
wrapperCppDefs Monad { monadStrType = StrictText,
                       monadUserState = False } = Just ["ALEX_MONAD_STRICT_TEXT"]
wrapperCppDefs Monad { monadStrType = Str,
                       monadUserState = True } = Just ["ALEX_MONAD", "ALEX_MONAD_USER_STATE"]
wrapperCppDefs Monad { monadStrType = Strict,
                       monadUserState = True } = Just ["ALEX_MONAD_BYTESTRING", "ALEX_MONAD_USER_STATE"]
wrapperCppDefs Monad { monadStrType = Lazy,
                       monadUserState = True } = Just ["ALEX_MONAD_BYTESTRING", "ALEX_MONAD_USER_STATE"]
wrapperCppDefs Monad { monadStrType = StrictText,
                       monadUserState = True } = Just ["ALEX_MONAD_STRICT_TEXT", "ALEX_MONAD_USER_STATE"]

-- TODO: update this comment
--
-- A `Scanner' consists of an association list associating token names with
-- regular expressions with context.  The context may include a list of start
-- codes, some leading context to test the character immediately preceding the
-- token and trailing context to test the residual input after the token.
--
-- The start codes consist of the names and numbers of the start codes;
-- initially the names only will be generated by the parser, the numbers being
-- allocated at a later stage.  Start codes become meaningful when scanners are
-- converted to DFAs; see the DFA section of the Scan module for details.

data Scanner = Scanner { scannerName   :: String,
                         scannerTokens :: [RECtx] }
  deriving Show

data RECtx = RECtx { reCtxStartCodes :: [(String,StartCode)],
                     reCtxPreCtx     :: Maybe CharSet,
                     reCtxRE         :: RExp,
                     reCtxPostCtx    :: RightContext RExp,
                     reCtxCode       :: Maybe Code
                   }

data RightContext r
  = NoRightContext
  | RightContextRExp r
  | RightContextCode Code
  deriving (Eq,Ord)

instance Show RECtx where
  showsPrec _ (RECtx scs _ r rctx code) =
        showStarts scs . shows r . showRCtx rctx . showMaybeCode code

showMaybeCode :: Maybe String -> String -> String
showMaybeCode Nothing = id
showMaybeCode (Just code) = showCode code

showCode :: String -> String -> String
showCode code = showString " { " . showString code . showString " }"

showStarts :: [(String, StartCode)] -> String -> String
showStarts [] = id
showStarts scs = shows scs

showRCtx :: Show r => RightContext r -> String -> String
showRCtx NoRightContext = id
showRCtx (RightContextRExp r) = ('\\':) . shows r
showRCtx (RightContextCode code) = showString "\\ " . showCode code

-- -----------------------------------------------------------------------------
-- DFAs

data DFA s a = DFA
  { dfa_start_states :: [s],
    dfa_states       :: Map s (State s a)
  }

data State s a = State { state_acc :: [Accept a],
                         state_out :: IntMap s -- 0..255 only
                       }

type SNum = Int

data Accept a
  = Acc { accPrio       :: Int,
          accAction     :: Maybe a,
          accLeftCtx    :: Maybe CharSet, -- cannot be converted to byteset at this point.
          accRightCtx   :: RightContext SNum
    }
    deriving (Eq,Ord)

-- debug stuff
instance Show (Accept a) where
  showsPrec _ (Acc p _act _lctx _rctx) = shows p --TODO

type StartCode = Int

-- -----------------------------------------------------------------------------
-- Predicates / contexts

-- we can generate somewhat faster code in the case that
-- the lexer doesn't use predicates
data UsesPreds = UsesPreds | DoesntUsePreds
  deriving Eq

usesPreds :: DFA s a -> UsesPreds
usesPreds dfa
    | any acceptHasCtx [ acc | st  <- Map.elems (dfa_states dfa)
                             , acc <- state_acc st ]
    = UsesPreds
    | otherwise
    = DoesntUsePreds
  where
    acceptHasCtx Acc { accLeftCtx  = Nothing
                     , accRightCtx = NoRightContext } = False
    acceptHasCtx _                                    = True

-- -----------------------------------------------------------------------------
-- Regular expressions

-- `RExp' provides an abstract syntax for regular expressions.  `Eps' will
-- match empty strings; `Ch p' matches strings containing a single character
-- `c' if `p c' is true; `re1 :%% re2' matches a string if `re1' matches one of
-- its prefixes and `re2' matches the rest; `re1 :|| re2' matches a string if
-- `re1' or `re2' matches it; `Star re', `Plus re' and `Ques re' can be
-- expressed in terms of the other operators.  See the definitions of `ARexp'
-- for a formal definition of the semantics of these operators.

data RExp
  = Eps            -- ^ Empty.
  | Ch CharSet     -- ^ Singleton.
  | RExp :%% RExp  -- ^ Sequence.
  | RExp :|| RExp   -- ^ Alternative.
  | Star RExp      -- ^ Zero or more repetitions.
  | Plus RExp      -- ^ One  or more repetitions.
  | Ques RExp      -- ^ Zero or one  repetitions.

instance Show RExp where
  showsPrec _ Eps = showString "()"
  showsPrec _ (Ch _) = showString "[..]"
  showsPrec _ (l :%% r)  = shows l . shows r
  showsPrec _ (l :|| r)  = shows l . ('|':) . shows r
  showsPrec _ (Star r) = shows r . ('*':)
  showsPrec _ (Plus r) = shows r . ('+':)
  showsPrec _ (Ques r) = shows r . ('?':)

-- | A regular expression is nullable if it matches the empty string.
nullable :: RExp -> Bool
nullable Eps       = True
nullable Ch{}      = False
nullable (l :%% r) = nullable l && nullable r
nullable (l :||  r) = nullable l || nullable r
nullable Star{}    = True
nullable (Plus r)  = nullable r
nullable Ques{}    = True


{------------------------------------------------------------------------------
                          Abstract Regular Expression
------------------------------------------------------------------------------}


-- This section contains demonstrations; it is not part of Alex.

{-
-- This function illustrates `ARexp'. It returns true if the string in its
-- argument is matched by the regular expression.

recognise:: RExp -> String -> Bool
recognise re inp = any (==len) (ap_ar (arexp re) inp)
        where
        len = length inp


-- `ARexp' provides an regular expressions in abstract format.  Here regular
-- expressions are represented by a function that takes the string to be
-- matched and returns the sizes of all the prefixes matched by the regular
-- expression (the list may contain duplicates).  Each of the `RExp' operators
-- are represented by similarly named functions over ARexp.  The `ap' function
-- takes an `ARExp', a string and returns the sizes of all the prefixes
-- matching that regular expression.  `arexp' converts an `RExp' to an `ARexp'.


arexp:: RExp -> ARexp
arexp Eps = eps_ar
arexp (Ch p) = ch_ar p
arexp (re :%% re') = arexp re `seq_ar` arexp re'
arexp (re :|| re') = arexp re `bar_ar` arexp re'
arexp (Star re) = star_ar (arexp re)
arexp (Plus re) = plus_ar (arexp re)
arexp (Ques re) = ques_ar (arexp re)


star_ar:: ARexp -> ARexp
star_ar sc =  eps_ar `bar_ar` plus_ar sc

plus_ar:: ARexp -> ARexp
plus_ar sc = sc `seq_ar` star_ar sc

ques_ar:: ARexp -> ARexp
ques_ar sc = eps_ar `bar_ar` sc


-- Hugs abstract type definition -- not for GHC.

type ARexp = String -> [Int]
--      in ap_ar, eps_ar, ch_ar, seq_ar, bar_ar

ap_ar:: ARexp -> String -> [Int]
ap_ar sc = sc

eps_ar:: ARexp
eps_ar inp = [0]

ch_ar:: (Char->Bool) -> ARexp
ch_ar p "" = []
ch_ar p (c:rst) = if p c then [1] else []

seq_ar:: ARexp -> ARexp -> ARexp
seq_ar sc sc' inp = [n+m| n<-sc inp, m<-sc' (drop n inp)]

bar_ar:: ARexp -> ARexp -> ARexp
bar_ar sc sc' inp = sc inp ++ sc' inp
-}

-- -----------------------------------------------------------------------------
-- Utils

-- Map the available start codes onto [1..]

encodeStartCodes:: Scanner -> (Scanner,[StartCode],ShowS)
encodeStartCodes scan = (scan', 0 : map snd name_code_pairs, sc_hdr)
        where
        scan' = scan{ scannerTokens = map mk_re_ctx (scannerTokens scan) }

        mk_re_ctx (RECtx scs lc re rc code)
          = RECtx (map mk_sc scs) lc re rc code

        mk_sc (nm,_) = (nm, if nm=="0" then 0
                                       else fromJust (Map.lookup nm code_map))

        sc_hdr tl =
                case name_code_pairs of
                  [] -> tl
                  (nm,_):rst -> "\n" ++ nm ++ foldr f t rst
                        where
                        f (nm', _) t' = "," ++ nm' ++ t'
                        t = " :: Int\n" ++ foldr fmt_sc tl name_code_pairs
                where
                fmt_sc (nm,sc) t = nm ++ " = " ++ show sc ++ "\n" ++ t

        code_map = Map.fromList name_code_pairs

        name_code_pairs = zip (nub' (<=) nms) [1..]

        nms = [nm | RECtx{reCtxStartCodes = scs} <- scannerTokens scan,
                    (nm,_) <- scs, nm /= "0"]


-- Grab the code fragments for the token actions, and replace them
-- with function names of the form alex_action_$n$.  We do this
-- because the actual action fragments might be duplicated in the
-- generated file.

extractActions :: Scheme -> Scanner -> (Scanner,ShowS)
extractActions scheme scanner = (scanner{scannerTokens = new_tokens}, decl_str . nl)
 where
  (new_tokens, decls) = unzip (zipWith f (scannerTokens scanner) act_names)

  f r@(RECtx{ reCtxCode = Just code }) name
        = (r{reCtxCode = Just name}, Just (mkDecl name code))
  f r@(RECtx{ reCtxCode = Nothing }) _
        = (r{reCtxCode = Nothing}, Nothing)

  gscanActionType res =
      str "AlexPosn -> Char -> String -> Int -> ((Int, state) -> "
    . str res . str ") -> (Int, state) -> " . str res

  mkDecl  fun code = mkTySig fun
                   . mkDef fun code

  mkDef   fun code = str fun . str " = " . str code . nl

  mkTySig fun = case scheme of
    Default { defaultTypeInfo = Just (Nothing, actionty) } -> nl .
        str fun . str " :: " . str actionty . nl
    Default { defaultTypeInfo = Just (Just tyclasses, actionty) } -> nl .
      str fun . str " :: (" . str tyclasses . str ") => " .
      str actionty . nl
    GScan { gscanTypeInfo = Just (Nothing, tokenty) } -> nl .
        str fun . str " :: " . gscanActionType tokenty . nl
    GScan { gscanTypeInfo = Just (Just tyclasses, tokenty) } -> nl .
      str fun . str " :: (" . str tyclasses . str ") => " .
      gscanActionType tokenty . nl
    Basic { basicStrType = strty, basicTypeInfo = Just (Nothing, tokenty) } -> nl .
      str fun . str " :: " . str (show strty) . str " -> "
      . str tokenty . nl
    Basic { basicStrType = strty,
            basicTypeInfo = Just (Just tyclasses, tokenty) } -> nl .
      str fun . str " :: (" . str tyclasses . str ") => " .
      str (show strty) . str " -> " . str tokenty . nl
    Posn { posnStrType = strty,
           posnTypeInfo = Just (Nothing, tokenty) } -> nl .
      str fun . str " :: AlexPosn -> " . str (show strty) . str " -> "
      . str tokenty . nl
    Posn { posnStrType = strty,
           posnTypeInfo = Just (Just tyclasses, tokenty) } -> nl .
      str fun . str " :: (" . str tyclasses . str ") => AlexPosn -> " .
      str (show strty) . str " -> " . str tokenty . nl
    Monad { monadStrType = strty,
            monadTypeInfo = Just (Nothing, tokenty) } -> nl .
      let
        actintty = if strty == Lazy then "Int64" else "Int"
      in
        str fun . str " :: AlexInput -> " . str actintty . str " -> Alex ("
      . str tokenty . str ")" . nl
    Monad { monadStrType = strty,
            monadTypeInfo = Just (Just tyclasses, tokenty) } -> nl .
      let
        actintty = if strty == Lazy then "Int64" else "Int"
      in
        str fun . str " :: (" . str tyclasses . str ") =>"
      . str " AlexInput -> " . str actintty
      . str " -> Alex (" . str tokenty . str ")" . nl
    _ -> id

  act_names = map (\n -> "alex_action_" ++ show (n::Int)) [0..]

  decl_str :: ShowS
  decl_str = foldr (.) id [ decl | Just decl <- decls ]

-- -----------------------------------------------------------------------------
-- Code generation targets

data Target = GhcTarget | HaskellTarget
  deriving Eq
