{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}

module Process where

import Data.Maybe
import System.IO.Unsafe
import Text.Pandoc
import Text.Pandoc.Walk
import Data.Monoid
import Control.Monad
import System.Process
import Text.Regex
import Text.Regex.TDFA
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.IO as T
import Data.List
import Tables
import Control.Monad.Writer
import Debug.Trace
import Data.List.Split
import qualified Data.Set as Set

data MatchMode = 
    Word      -- "an" will not match in "Dan"
  | Anywhere  -- "+" will match in "a+b"
  deriving (Read, Show)

extractMacro :: [(Text, Text)] -> (Text, Text, MatchMode)
extractMacro row = fromJust $ do
  s <- lookup "Search For" row
  r <- lookup "Replace With" row
  let r' = if r == "_" then s else r
  m <- liftM (read . T.unpack) $ lookup "Match Mode" row
  return (s, r', m)

getMacros :: FilePath -> [(Text, Text, MatchMode)]
getMacros = map extractMacro . tableRows . unsafePerformIO . parseTableIO

alterMacro :: (Text -> Text) -> (Text, Text, MatchMode) -> (Text, Text, MatchMode)
alterMacro f (s,r,m) = (s,f r,m)

wrapMacro :: Text -> (Text, Text, MatchMode) -> (Text, Text, MatchMode)
wrapMacro c = alterMacro $ \ r -> T.concat [ "\\" , c ,  "{" , r , "}" ]

allMacros :: [(Text,Text,MatchMode)]
allMacros = concat
  [ getMacros "Process_pre_macros.tbl"
  , map (wrapMacro "ttbfop") $ getMacros "Process_ttbf_op.tbl"
  , map (wrapMacro "itop") $ getMacros "Process_it_op.tbl"
  , getMacros "Process_post_macros.tbl"
  ]

regexmeta :: [Text]
regexmeta = [ "\\" , "|" , "(" , ")" , "[" , "]" , "{" , "}" , "^" , "$" , "*" , "+" , "?" , "." ]

escapeRegex :: Text -> Text
escapeRegex = appEndo $ execWriter $ forM_ (reverse regexmeta) $ \ c -> do
  tell $ Endo $ T.replace c $ T.concat ["\\", c]

macroText :: Text -> Text
macroText = appEndo $ execWriter $ forM_ (reverse allMacros) $ \ (s,r,m) -> do
  let escaped = escapeRegex s
      withMode = case m of
        Word -> T.concat ["([^-]|^)\\<",escaped,"\\>([^-]|$)"]
        Anywhere -> escaped
      regex = mkRegex $ T.unpack withMode
      replace = T.unpack $ T.concat $ case m of
        Word -> [" \\1", r, "\\2 "]
        Anywhere -> [" ", r, " "]
  tell $ Endo $ \ t -> T.pack $ subRegex regex (T.unpack t) replace

ops :: ReaderOptions
ops = def 
  { readerExtensions = 
      readerExtensions def 
      Set.\\ 
      Set.empty
      -- Set.fromList [ Ext_raw_tex , Ext_tex_math_dollars ]
  , readerSmart = True
  }

main :: IO ()
main = do
  s <- T.readFile "paper.markdown"
  let pre = preProcess s
      md = readMarkdown ops  $ T.unpack pre
      post = postProcess md
  system "mkdir -p tmp/autogen"
  T.writeFile "tmp/autogen/paper.markdown.pre" pre
  T.writeFile "tmp/autogen/paper.markdown.tex" $ T.pack $ writeLaTeX def post

-- Pre Processing {{{

preProcess :: Text -> Text
preProcess = addPars . stripComments

stripComments :: Text -> Text
stripComments = newlines . map fixEmpties . filter (not . isComment) . T.lines
  where
    isComment :: Text -> Bool
    isComment s = T.unpack s =~ ("^\\s*--\\s" :: String)
    fixEmpties :: Text -> Text
    fixEmpties s = if T.unpack s =~ ("^\\s*$" :: String) then "" else s

addPars :: Text -> Text
addPars = newlines . addPar . T.lines
  where
    addPar :: [Text] -> [Text]
    addPar = intercalate ["\n<!-- -->","\\par","<!-- -->\n"] . splitOn [""]

-- }}}

-- Post Processing {{{

postProcess :: Pandoc -> Pandoc
postProcess = walkInlineMath . walkBlocksMath . walkInlineRaw . walkBlocksRaw
  where
    walkBlocksRaw = walk $ \ (b :: Block) -> case b of
      CodeBlock (_,[c],_) s
        | "verb" `isPrefixOf` c -> RawBlock (Format "latex") $ T.unpack $ newlines
          [ "\\begin{verbatim}"
          , macroText $ T.pack s
          , "\\end{verbatim}"
          ]
        | "rawmacro" `isPrefixOf` c -> RawBlock (Format "latex") $ T.unpack $ macroText $ T.pack s
        | "raw" `isPrefixOf` c -> RawBlock (Format "latex") s
      _ -> b
    walkInlineRaw = walk $ \ (i :: Inline) -> case i of
      Code (_,[c],_) s
        | "raw" `isPrefixOf` c -> RawInline (Format "latex") s
      _ -> i
    walkBlocksMath :: Pandoc -> Pandoc
    walkBlocksMath = walk $ \ (b :: Block) -> case b of
      CodeBlock (_,[c],_) s 
        | "align" `isPrefixOf` c -> alignBlock $ T.pack s
        | "indent" `isPrefixOf` c -> indentBlock $ T.pack s
      _ -> b
    walkInlineMath :: Pandoc -> Pandoc
    walkInlineMath = walk $ \ (i :: Inline) -> case i of
      Code _ s -> RawInline (Format "latex") $ T.unpack $ T.concat
        [ "$"
        , macroText $ T.pack s
        , "$"
        ]
      _ -> i

-- Align {{{

alignBlock :: Text -> Block
alignBlock s = 
  let (cols,lines) = alignLines $ T.lines s
  in RawBlock (Format "latex") $ T.unpack $ newlines
    [ T.concat [ "\\small\\begin{alignat*}{" , T.pack (show cols) , "}" ]
    , newlines lines
    , "\\end{alignat*}\\normalsize"
    ] 
alignLines :: [Text] -> (Int,[Text])
alignLines s = 
  let (ns,lines) = unzip $ map alignLine s
  in (maximum ns, addAlignEndings lines)
alignLine :: Text -> (Int,Text)
alignLine s = 
  let stripped = T.strip s
      cols = filter ((/=) "") . map T.strip $ T.splitOn "  " stripped
      len = length cols
  in (len, format True cols)
  where
    format :: Bool -> [Text] -> Text
    format _ [] = ""
    format _ [t] = macroText t
    format i (t:ts) = T.unwords
      [ macroText t
      , if i then "&" else "&&"
      , format False ts
      ]

-- }}}

-- Indent {{{

indentBlock :: Text -> Block
indentBlock s =
  let lines = map indentLine $ T.lines s
  in RawBlock (Format "latex") $ T.unpack $ newlines
    [ "\\small\\begin{align*}"
    , newlines $ addAlignEndings lines
    , "\\end{align*}\\normalsize"
    ]

indentLine :: Text -> Text
indentLine t =
  let (whites, text) = T.span ((==) ' ') t
  in T.unwords
    [ T.concat [ "&\\hspace{", T.pack $ show $ T.length whites, "em}" ]
    , macroText text
    ]

-- }}}

-- }}}

-- Helpers {{{

newlines :: [Text] -> Text
newlines = T.intercalate "\n"

mapAllButLast :: (a -> a) -> [a] -> [a]
mapAllButLast _ [] = []
mapAllButLast _ [a] = [a]
mapAllButLast f (x:xs) = f x:mapAllButLast f xs

addAlignEndings :: [Text] -> [Text]
addAlignEndings = mapAllButLast {- map -} $ \ t -> T.unwords [t, "\\\\"]

-- }}}