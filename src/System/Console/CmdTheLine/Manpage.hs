{- Copyright © 2012, Vincent Elisha Lee Frey.  All rights reserved.
 - This is open source software distributed under a MIT license.
 - See the file 'LICENSE' for further information.
 -}
module System.Console.CmdTheLine.Manpage where

import System.Console.CmdTheLine.Common

import Control.Applicative hiding ( (<|>), many, empty )

import System.Cmd         ( system )
import System.Environment ( getEnv )
import System.Directory   ( findExecutable )
import System.Exit        ( ExitCode(..) )
import System.IO.Error    ( isDoesNotExistError )
import System.IO

import Control.Exception ( handle, throw, IOException )

import Data.Maybe ( catMaybes )
import Data.Char  ( isSpace )

import Text.Parsec
import Text.PrettyPrint hiding ( char )

type Subst = [( String, String )] -- An association list of
                                  -- ( replacing, replacement ) pairs.

paragraphIndent = 7
labelIndent     = 4

mkEscape :: Subst -> (Char -> String -> String) -> String -> String
mkEscape subst esc str = sub $ sub str -- Twice for nested substitutions.
  where
  sub str
    | not $ len > 1 && str !! 2 == ',' = substitute subst str
    | len == 2                         = ""
    | otherwise                        = esc (head str) (drop 2 str)
    where
    len = length str

mkPrepTokens :: Bool -> String -> String
mkPrepTokens roff = either (error . ("printTokens: "++) . show) id
                 . parse process ""
  where
  process      = concat <$> many (squashSpaces <|> dash <|> otherChars) 
  squashSpaces = spaces >> return " "
  dash         = char '-' >> return "\\-"
  otherChars   = many1 $ satisfy (\ x -> not $ isSpace x || x == '-')

-- `subsitute assoc input` where `assoc` is an association list of
-- `( replacing, replacement )` pairs.  Replaces all occurances of
-- `"$(" ++ replacing ++ ")"` in `input` with `replacement`.
--
-- TODO: return `Either String String` and produce more informative errors
-- downstream.
substitute :: Subst -> String -> String
substitute assoc = either (error . show) id . parse subst ""
  where
  subst = fmap concat . many
        $ try (string "\\$") <|> try replace <|> pure <$> anyChar

  replace = do
    string "$("
    replacement <- choice $ map mkReplacer assoc
    char ')'
    return replacement

  mkReplacer ( replacing, replacement ) = replacement <$ string replacing


--
-- Plain text output
--

plainEsc :: Char -> String -> String
plainEsc 'g' _   = ""
plainEsc _   str = str

indent :: Int -> String
indent n = take n $ repeat ' '

prepPlainBlocks :: Subst -> [ManBlock] -> String
prepPlainBlocks subst = show . go empty
  where
  escape     = mkEscape subst plainEsc
  prepTokens = mkPrepTokens False . escape

  go :: Doc -> [ManBlock] -> Doc
  go acc []             = acc
  go acc (block : rest) = go acc' rest
    where
    acc' = case block of
      NoBlank     -> acc
      P str       -> acc $+$ nest paragraphIndent (text $ prepTokens str)
      S str       -> acc $+$ text (prepTokens str)
      I label str -> prepLabel label str

    prepLabel label str =
      acc $+$ nest paragraphIndent (text $ prepTokens label') $+$ content
      where
      content
        | str == ""        = empty
        | ll < labelIndent = doc
        | otherwise        = text "" $+$ doc

      doc = nest (labelIndent - ll) (text $ prepTokens str)

      label' = escape label

      ll = length label'

printPlainPage :: Subst -> Handle -> Page -> IO ()
printPlainPage subst h ( _, blocks ) =
  hPutStrLn h $ prepPlainBlocks subst blocks


--
-- Groff output
--

groffEsc :: Char -> String -> String
groffEsc c str = case c of
 'i' -> "\\fI" ++ str ++ "\\fR"
 'b' -> "\\fB" ++ str ++ "\\fR"
 'p' -> ""
 _   -> str

prepGroffBlocks :: Subst -> [ManBlock] -> String
prepGroffBlocks subst blocks = prep =<< blocks
  where
  escape     = mkEscape subst groffEsc
  prepTokens = mkPrepTokens True . escape
  prep block = case block of
    P str       -> "\n.P\n" ++ prepTokens str
    S str       -> "\n.SH " ++ prepTokens str
    I label str -> "\n.TP 4\n" ++ prepTokens label ++ "\n" ++ prepTokens str
    NoBlank     -> "\n.sp -1"

printGroffPage :: Subst -> Handle -> Page -> IO ()
printGroffPage subst h page = hPutStrLn h $ unlines
  [ ".\\\" Pipe this output to groff -man -Tutf8 | less"
  , ".\\\""
  , concat [ ".TH \"", n, "\" ", show s
           , " \"", a1, "\" \"", a2, "\" \"", a3, "\"" ]
  , ".\\\" Disable hyphenation and ragged-right"
  , ".nh"
  , ".ad l"
  , prepGroffBlocks subst blocks
  ]
  where
  ( ( n, s, a1, a2, a3 ), blocks ) = page


--
-- Pager output
--

printToPager :: (HFormat -> Handle -> Page -> IO ()) -> Handle -> Page -> IO ()
printToPager print h page = do
  pagers <- do
    name <- handle handler $ pure <$> getEnv "PAGER"

    return $ name ++ [ "less", "more" ]
  
  found <- catMaybes <$> mapM findExecutable pagers

  case found of
    []        -> print Plain h page
    pager : _ -> do
      roffs <- catMaybes <$> mapM findExecutable [ "groff", "nroff" ]

      mCmd <- case roffs of
        []       -> (fmap . fmap) (naked pager)
                  $ printToTempFile (print Plain) page

        roff : _ -> (fmap . fmap) (preped roff pager)
                  $ printToTempFile (print Groff) page

      case mCmd of
        Nothing  -> print Plain h page
        Just cmd -> do exitStatus <- system cmd
                       case exitStatus of
                            ExitSuccess   -> return ()
                            ExitFailure _ -> print Plain h page
  where
  preped roff pager tmpFile =
    concat [ xroff, " -man < ", tmpFile, " | ", pager ]
    where
    xroff | roff == "groff" = roff ++ " -Tascee"
          | otherwise       = roff

  naked pager tmpFile = pager ++ " < " ++ tmpFile

  handler :: IOException -> IO [String]
  handler e
    | isDoesNotExistError e = return []
    | otherwise             = throw e


--
-- Interface
--

print :: Subst -> HFormat -> Handle -> Page -> IO ()
print subst fmt = case fmt of
  Pager -> printToPager   (System.Console.CmdTheLine.Manpage.print subst)
  Plain -> printPlainPage subst
  Groff -> printGroffPage subst
