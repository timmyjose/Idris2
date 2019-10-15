module Idris.IDEMode.REPL

import Compiler.Scheme.Chez
import Compiler.Scheme.Chicken
import Compiler.Scheme.Racket
import Compiler.Common

import Core.AutoSearch
import Core.CompileExpr
import Core.Context
import Core.InitPrimitives
import Core.Metadata
import Core.Normalise
import Core.Options
import Core.TT
import Core.Unify

import Idris.Desugar
import Idris.Error
import Idris.ModTree
import Idris.Parser
import Idris.Resugar
import Idris.REPL
import Idris.Syntax
import Idris.Version

import Idris.IDEMode.Parser
import Idris.IDEMode.Commands

import TTImp.Interactive.CaseSplit
import TTImp.Elab
import TTImp.TTImp
import TTImp.ProcessDecls

import Control.Catchable
import System
import Idris.Socket
import Idris.Socket.Data

export
socketToFile : Socket -> IO (Either String File)
socketToFile (MkSocket f _ _ _) = do
  file <- map FHandle $ foreign FFI_C "fdopen" (Int -> String -> IO Ptr) f "r+"
  if !(ferror file) then do
    pure (Left "Failed to fdopen socket file descriptor")
  else pure (Right file)

export
initIDESocketFile : String -> Int -> IO (Either String File)
initIDESocketFile h p = do
  osock <- socket AF_INET Stream 0
  case osock of
    Left fail => do
      putStrLn (show fail)
      putStrLn "Failed to open socket"
      exit 1
    Right sock => do
      res <- bind sock (Just (Hostname h)) p
      if res /= 0
      then
        pure (Left ("Failed to bind socket with error: " ++ show res))
      else do
        res <- listen sock
        if res /= 0
        then
          pure (Left ("Failed to listen on socket with error: " ++ show res))
        else do
          putStrLn (show p)
          res <- accept sock
          case res of
            Left err =>
               pure (Left ("Failed to accept on socket with error: " ++ show err))
            Right (s, _) =>
               socketToFile s

getChar : File -> IO Char
getChar (FHandle h) = do
  if !(fEOF (FHandle h)) then do
    putStrLn "Alas the file is done, aborting"
    exit 1
  else do
    chr <- map cast $ foreign FFI_C "fgetc" (Ptr -> IO Int) h
    if !(ferror (FHandle h)) then do
      putStrLn "Failed to read a character"
      exit 1
    else pure chr

getFLine : File -> IO String
getFLine (FHandle h) = do
  str <- prim_fread h
  if !(ferror (FHandle h)) then do
    putStrLn "Failed to read a line"
    exit 1
  else pure str

getNChars : File -> Nat -> IO (List Char)
getNChars i Z = pure []
getNChars i (S k)
    = do x <- getChar i
         xs <- getNChars i k
         pure (x :: xs)

hex : Char -> Maybe Int
hex '0' = Just 0
hex '1' = Just 1
hex '2' = Just 2
hex '3' = Just 3
hex '4' = Just 4
hex '5' = Just 5
hex '6' = Just 6
hex '7' = Just 7
hex '8' = Just 8
hex '9' = Just 9
hex 'a' = Just 10
hex 'b' = Just 11
hex 'c' = Just 12
hex 'd' = Just 13
hex 'e' = Just 14
hex 'f' = Just 15
hex _ = Nothing

export
toHex : Int -> List Char -> Maybe Int
toHex _ [] = Just 0
toHex m (d :: ds)
    = pure $ !(hex (toLower d)) * m + !(toHex (m*16) ds)


-- Read 6 characters. If they're a hex number, read that many characters.
-- Otherwise, just read to newline
getInput : File -> IO String
getInput f
    = do x <- getNChars f 6
         case toHex 1 (reverse x) of
              Nothing =>
                do rest <- getFLine f
                   pure (pack x ++ rest)
              Just num =>
                do inp <- getNChars f (cast num)
                   pure (pack inp)

process : {auto c : Ref Ctxt Defs} ->
          {auto u : Ref UST UState} ->
          {auto s : Ref Syn SyntaxInfo} ->
          {auto m : Ref MD Metadata} ->
          {auto o : Ref ROpts REPLOpts} ->
          IDECommand -> Core REPLResult
process (Interpret cmd)
    = interpret cmd
process (LoadFile fname _)
    = Idris.REPL.process (Load fname)
process (TypeOf n Nothing)
    = Idris.REPL.process (Check (PRef replFC (UN n)))
process (TypeOf n (Just (l, c)))
    = Idris.REPL.process (Editing (TypeAt (fromInteger l) (fromInteger c) (UN n)))
process (CaseSplit l c n)
    = Idris.REPL.process (Editing (CaseSplit (fromInteger l) (fromInteger c) (UN n)))
process (AddClause l n)
    = Idris.REPL.process (Editing (AddClause (fromInteger l) (UN n)))
process (ExprSearch l n hs all)
    = Idris.REPL.process (Editing (ExprSearch (fromInteger l) (UN n)
                                                 (map UN hs) all))
process (GenerateDef l n)
    = Idris.REPL.process (Editing (GenerateDef (fromInteger l) (UN n)))
process (MakeLemma l n)
    = Idris.REPL.process (Editing (MakeLemma (fromInteger l) (UN n)))
process (MakeCase l n)
    = Idris.REPL.process (Editing (MakeCase (fromInteger l) (UN n)))
process (MakeWith l n)
    = Idris.REPL.process (Editing (MakeWith (fromInteger l) (UN n)))
process Version
    = Idris.REPL.process ShowVersion
process (Metavariables _)
    = Idris.REPL.process Metavars
process GetOptions
    = pure Done

processCatch : {auto c : Ref Ctxt Defs} ->
               {auto u : Ref UST UState} ->
               {auto s : Ref Syn SyntaxInfo} ->
               {auto m : Ref MD Metadata} ->
               {auto o : Ref ROpts REPLOpts} ->
               IDECommand -> Core REPLResult
processCatch cmd
    = do c' <- branch
         u' <- get UST
         s' <- get Syn
         o' <- get ROpts
         catch (do res <- process cmd
                   commit
                   pure res)
               (\err => do put Ctxt c'
                           put UST u'
                           put Syn s'
                           put ROpts o'
                           msg <- perror err
                           pure $ REPLError msg)

idePutStrLn : File -> Int -> String -> Core ()
idePutStrLn outf i msg
    = send outf (SExpList [SymbolAtom "write-string",
                toSExp msg, toSExp i])

printIDEWithStatus : File -> Int -> String -> String -> Core ()
printIDEWithStatus outf i status msg
    = do let m = SExpList [SymbolAtom status, toSExp msg ]
         send outf (SExpList [SymbolAtom "return", m, toSExp i])

printIDEResult : File -> Int -> String -> Core ()
printIDEResult outf i msg = printIDEWithStatus outf i "ok" msg

printIDEError : File -> Int -> String -> Core ()
printIDEError outf i msg = printIDEWithStatus outf i "error" msg

displayIDEResult : {auto c : Ref Ctxt Defs} ->
       {auto u : Ref UST UState} ->
       {auto s : Ref Syn SyntaxInfo} ->
       {auto m : Ref MD Metadata} ->
       {auto o : Ref ROpts REPLOpts} ->
       File -> Int -> REPLResult -> Core ()
displayIDEResult outf i  (REPLError err) = printIDEError outf i err
displayIDEResult outf i  (Evaluated x Nothing) = printIDEResult outf i $ show x
displayIDEResult outf i  (Evaluated x (Just y)) = printIDEResult outf i $ show x ++ " : " ++ show y
displayIDEResult outf i  (Printed xs) = printIDEResult outf i (showSep "\n" xs)
displayIDEResult outf i  (TermChecked x y) = printIDEResult outf i $ show x ++ " : " ++ show y
displayIDEResult outf i  (FileLoaded x) = printIDEResult outf i $ "Loaded file " ++ x
displayIDEResult outf i  (ErrorLoadingFile x err) = printIDEError outf i $ "Error loading file " ++ x ++ ": " ++ show err
displayIDEResult outf i  (ErrorsBuildingFile x errs) = printIDEError outf i $ "Error(s) building file " ++ x ++ ": " ++ (showSep "\n" $ map show errs)
displayIDEResult outf i  NoFileLoaded = printIDEError outf i "No file can be reloaded"
displayIDEResult outf i  (ChangedDirectory dir) = printIDEResult outf i ("Changed directory to " ++ dir)
displayIDEResult outf i  CompilationFailed = printIDEError outf i "Compilation failed"
displayIDEResult outf i  (Compiled f) = printIDEResult outf i $ "File " ++ f ++ " written"
displayIDEResult outf i  (ProofFound x) = printIDEResult outf i $ show x
--displayIDEResult outf i  (Missed cases) = printIDEResult outf i $ showSep "\n" $ map handleMissing cases
displayIDEResult outf i  (CheckedTotal xs) = printIDEResult outf i $ showSep "\n" $ map (\ (fn, tot) => (show fn ++ " is " ++ show tot)) xs
displayIDEResult outf i  (FoundHoles []) = printIDEResult outf i $ "No holes"
displayIDEResult outf i  (FoundHoles [x]) = printIDEResult outf i $ "1 hole: " ++ show x
displayIDEResult outf i  (FoundHoles xs) = printIDEResult outf i $ show (length xs) ++ " holes: " ++
                                 showSep ", " (map show xs)
displayIDEResult outf i  (LogLevelSet k) = printIDEResult outf i $ "Set loglevel to " ++ show k
displayIDEResult outf i  (VersionIs x) = printIDEResult outf i $ showVersion x
displayIDEResult outf i  (Edited (DisplayEdit xs)) = printIDEResult outf i $ showSep "\n" xs
displayIDEResult outf i  (Edited (EditError x)) = printIDEError outf i x
displayIDEResult outf i  (Edited (MadeLemma name pty pappstr)) = printIDEResult outf i (show name ++ " : " ++ show pty ++ "\n" ++ pappstr)
displayIDEResult outf i  _ = pure ()


handleIDEResult : {auto c : Ref Ctxt Defs} ->
       {auto u : Ref UST UState} ->
       {auto s : Ref Syn SyntaxInfo} ->
       {auto m : Ref MD Metadata} ->
       {auto o : Ref ROpts REPLOpts} ->
       File -> Int -> REPLResult -> Core ()
handleIDEResult outf i Exited = idePutStrLn outf i "Bye for now!"
handleIDEResult outf i other = displayIDEResult outf i other

loop : {auto c : Ref Ctxt Defs} ->
       {auto u : Ref UST UState} ->
       {auto s : Ref Syn SyntaxInfo} ->
       {auto m : Ref MD Metadata} ->
       {auto o : Ref ROpts REPLOpts} ->
       Core ()
loop
    = do res <- getOutput
         case res of
              REPL _ => printError "Running idemode but output isn't"
              IDEMode idx inf outf => do
                inp <- coreLift $ getInput inf
                end <- coreLift $ fEOF inf
                if end then pure ()
                else case parseSExp inp of
                  Left err =>
                    do printIDEError outf idx ("Parse error: " ++ show err)
                       loop
                  Right sexp =>
                    case getMsg sexp of
                      Just (cmd, i) =>
                        do updateOutput i
                           res <- processCatch cmd
                           handleIDEResult outf idx res
                           loop
                      Nothing =>
                        do printIDEError ("Unrecognised command: " ++ show sexp)
                           loop
  where
    updateOutput : Integer -> Core ()
    updateOutput idx
        = do IDEMode _ i o <- getOutput
                 | _ => pure ()
             setOutput (IDEMode idx i o)

export
replIDE : {auto c : Ref Ctxt Defs} ->
          {auto u : Ref UST UState} ->
          {auto s : Ref Syn SyntaxInfo} ->
          {auto m : Ref MD Metadata} ->
          {auto o : Ref ROpts REPLOpts} ->
          Core ()
replIDE
    = do res <- getOutput
         case res of
              REPL _ => printError "Running idemode but output isn't"
              IDEMode _ inf outf => do
                send outf (version 2 0)
                loop
