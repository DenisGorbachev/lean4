/-
Copyright (c) 2018 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura, Sebastian Ullrich

Implementation for the Parsec Parser Combinators described in the
paper:
https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/Parsec-paper-letter.pdf
-/
prelude
import init.data.tostring init.data.string.basic init.data.list.basic init.control.except
import init.data.repr init.lean.name init.data.dlist init.control.monadfail init.control.combinators

namespace Lean
namespace Parser
open String (Iterator)

namespace Parsec
@[reducible] def Position : Type := Nat

structure Message (μ : Type := unit) :=
(it         : Iterator)
(unexpected : String       := "")          -- unexpected input
(expected   : Dlist String := Dlist.Empty) -- expected productions
(custom     : Option μ)

def expected.toString : List String → String
| []       := ""
| [e]      := e
| [e1, e2] := e1 ++ " or " ++ e2
| (e::es)  := e ++ ", " ++ expected.toString es

def Message.text {μ : Type} (msg : Message μ) : String :=
let unexpected := (if msg.unexpected = "" then [] else ["unexpected " ++ msg.unexpected]) in
let exList := msg.expected.toList in
let expected := if exList = [] then [] else ["expected " ++ expected.toString exList] in
"\n".intercalate $ unexpected ++ expected


protected def Message.toString {μ : Type} (msg : Message μ) : String :=
let (line, col) := msg.it.toString.lineColumn msg.it.offset in
-- always print ":"; we assume at least one of `unexpected` and `expected` to be non-Empty
"error at line " ++ toString line ++ ", column " ++ toString col ++ ":\n" ++ msg.text

instance {μ : Type} : HasToString (Message μ) :=
⟨Message.toString⟩

-- use for e.g. upcasting Parsec errors with `MonadExcept.liftExcept`
instance {μ : Type} : HasLift (Message μ) String :=
⟨toString⟩

/-
Remark: we store expected "error" messages in `okEps` results.
They contain the error that would have occurred if a
successful "epsilon" Alternative was not taken.
-/
inductive Result (μ α : Type)
| ok {} (a : α) (it : Iterator) (expected : Option $ Dlist String) : Result
| error {} (msg : Message μ) (consumed : Bool)                     : Result

@[inline] def Result.mkEps {μ α : Type} (a : α) (it : Iterator) : Result μ α :=
Result.ok a it (some Dlist.Empty)
end Parsec

open Parsec

def ParsecT (μ : Type) (m : Type → Type) (α : Type) :=
Iterator → m (Result μ α)

abbrev Parsec (μ : Type) := ParsecT μ id
/-- `Parsec` without custom error Message Type -/
abbrev Parsec' := Parsec unit

namespace ParsecT
open Parsec.Result
variables {m : Type → Type} [Monad m] {μ α β : Type}

def run (p : ParsecT μ m α) (s : String) (fname := "") : m (Except (Message μ) α) :=
do r ← p s.mkIterator,
   pure $ match r with
   | ok a _ _     := Except.ok a
   | error msg _  := Except.error msg

def runFrom (p : ParsecT μ m α) (it : Iterator) (fname := "") : m (Except (Message μ) α) :=
do r ← p it,
   pure $ match r with
   | ok a _ _     := Except.ok a
   | error msg _  := Except.error msg

@[inline] protected def pure (a : α) : ParsecT μ m α :=
λ it, pure (mkEps a it)

def eps : ParsecT μ m unit :=
ParsecT.pure ()

protected def failure : ParsecT μ m α :=
λ it, pure (error { unexpected := "failure", it := it, custom := none } ff)

def merge (msg₁ msg₂ : Message μ) : Message μ :=
{ expected := msg₁.expected ++ msg₂.expected, ..msg₁ }

@[inlineIfReduce] def bindMkRes (ex₁ : Option (Dlist String)) (r : Result μ β) : Result μ β :=
match ex₁, r with
| none,     ok b it _          := ok b it none
| none,     error msg _        := error msg tt
| some ex₁, ok b it (some ex₂) := ok b it (some $ ex₁ ++ ex₂)
| some ex₁, error msg₂ ff      := error { expected := ex₁ ++ msg₂.expected, .. msg₂ } ff
| some ex₁, other              := other

/--
  The `bind p q` Combinator behaves as follows:
  1- If `p` fails, then it fails.
  2- If `p` succeeds and consumes input, then execute `q`
  3- If `q` succeeds but does not consume input, then execute `q`
     and merge error messages if both do not consume any input.
-/
@[inline] protected def bind (p : ParsecT μ m α) (q : α → ParsecT μ m β) : ParsecT μ m β :=
λ it, do
 r ← p it,
 match r with
 | ok a it ex₁  := bindMkRes ex₁ <$> q a it
 | error msg c  := pure (error msg c)

/-- More efficient `bind` that does not correctly merge `expected` and `consumed` information. -/
@[inline] def bind' (p : ParsecT μ m α) (q : α → ParsecT μ m β) : ParsecT μ m β :=
λ it, do
 r ← p it,
 match r with
 | ok a it ex₁  := q a it
 | error msg c  := pure (error msg c)

instance : Monad (ParsecT μ m) :=
{ bind := λ _ _, ParsecT.bind, pure := λ _, ParsecT.pure }

/-- `Monad` instance using `bind'`. -/
def Monad' : Monad (ParsecT μ m) :=
{ bind := λ _ _, ParsecT.bind', pure := λ _, ParsecT.pure }

instance : MonadFail Parsec' :=
{ fail := λ _ s it, error { unexpected := s, it := it, custom := () } ff }

instance : MonadExcept (Message μ) (ParsecT μ m) :=
{ throw := λ _ msg it, pure (error msg ff),
  catch := λ _ p c it, do
    r ← p it,
    match r with
    | error msg cns := do {
      r ← c msg msg.it,
      pure $ match r with
      | error msg' cns' := error msg' (cns || cns')
      | other := other }
    | other       := pure other }

instance : HasMonadLift m (ParsecT μ m) :=
{ monadLift := λ α x it, do a ← x, pure (mkEps a it) }

def expect (msg : Message μ) (exp : String) : Message μ :=
{expected := Dlist.singleton exp, ..msg}

@[inlineIfReduce] def labelsMkRes (r : Result μ α) (lbls : Dlist String) : Result μ α :=
match r with
  | ok a it (some _) := ok a it (some lbls)
  | error msg ff     := error {expected := lbls, ..msg} ff
  | other            := other

@[inline] def labels (p : ParsecT μ m α) (lbls : Dlist String) : ParsecT μ m α :=
λ it, do
  r ← p it,
  pure $ labelsMkRes r lbls

@[inlineIfReduce] def tryMkRes (r : Result μ α) : Result μ α :=
match r with
| error msg _  := error msg ff
| other        := other

/--
`try p` behaves like `p`, but it pretends `p` hasn't
consumed any input when `p` fails.

It is useful for implementing infinite lookahead.
The Parser `try p <|> q` will try `q` even when
`p` has consumed input.

It is also useful for specifying both the lexer and Parser
together.
```
    (do try (ch 'l' >> ch 'e' >> ch 't'), whitespace, ...)
    <|>
    ...
```
Without the `try` Combinator we will not be able to backtrack on the `let` keyword.
-/
@[inline] def try (p : ParsecT μ m α) : ParsecT μ m α :=
λ it, do
  r ← p it,
  pure $ tryMkRes r

@[inlineIfReduce] def orelseMkRes (msg₁ : Message μ) (r : Result μ α) : Result μ α :=
match r with
| ok a it' (some ex₂) := ok a it' (some $ msg₁.expected ++ ex₂)
| error msg₂ ff       := error (merge msg₁ msg₂) ff
| other               := other

/--
  The `orelse p q` Combinator behaves as follows:
  1- If `p` succeeds *or* consumes input, return
     its Result. Otherwise, execute `q` and return its
     Result.
     Recall that the `try p` Combinator can be used to
     pretend that `p` did not consume any input, and
     simulate infinite lookahead.
  2- If both `p` and `q` did not consume any input, then
     combine their error messages (even if one of
     them succeeded).
-/
@[inline] protected def orelse (p q : ParsecT μ m α) : ParsecT μ m α :=
λ it, do
  r ← p it,
  match r with
  | error msg₁ ff := do { r ← q it, pure $ orelseMkRes msg₁ r }
  | other         := pure other

instance : Alternative (ParsecT μ m) :=
{ orelse         := λ _, ParsecT.orelse,
  failure        := λ _, ParsecT.failure,
  ..ParsecT.Monad }

/-- Run `p`, but do not consume any input when `p` succeeds. -/
@[specialize] def lookahead (p : ParsecT μ m α) : ParsecT μ m α :=
λ it, do
  r ← p it,
  pure $ match r with
  | ok a s' _ := mkEps a it
  | other     := other
end ParsecT

/- Type class for abstracting from concrete Monad stacks containing a `Parsec` somewhere. -/
class MonadParsec (μ : outParam Type) (m : Type → Type) :=
-- analogous to e.g. `MonadReader.lift` before simplification (see there)
(lift {} {α : Type} : Parsec μ α → m α)
-- Analogous to e.g. `MonadReaderAdapter.map` before simplification (see there).
-- Its usage seems to be way too common to justify moving it into a separate type class.
(map {} {α : Type} : (∀ {m'} [Monad m'] {α}, ParsecT μ m' α → ParsecT μ m' α) → m α → m α)

/-- `Parsec` without custom error Message Type -/
abbrev MonadParsec' := MonadParsec unit

variables {μ : Type}

instance {m : Type → Type} [Monad m] : MonadParsec μ (ParsecT μ m) :=
{ lift := λ α p it, pure (p it),
  map  := λ α f x, f x }

instance monadParsecTrans {m n : Type → Type} [HasMonadLift m n] [MonadFunctor m m n n] [MonadParsec μ m] : MonadParsec μ n :=
{ lift := λ α p, monadLift (MonadParsec.lift p : m α),
  map  := λ α f x, monadMap (λ β x, (MonadParsec.map @f x : m β)) x }

namespace MonadParsec
open ParsecT
variables {m : Type → Type} [Monad m] [MonadParsec μ m] {α β : Type}

def error {α : Type} (unexpected : String) (expected : Dlist String := Dlist.Empty)
          (it : Option Iterator := none) (custom : Option μ := none) : m α :=
lift $ λ it', Result.error { unexpected := unexpected, expected := expected, it := it.getOrElse it', custom := custom } ff

@[inline] def leftOver : m Iterator :=
lift $ λ it, Result.mkEps it it

/-- Return the number of characters left to be parsed. -/
@[inline] def remaining : m Nat :=
String.Iterator.remaining <$> leftOver

@[inline] def labels (p : m α) (lbls : Dlist String) : m α :=
map (λ m' inst β p, @ParsecT.labels m' inst μ β p lbls) p

@[inline] def label (p : m α) (lbl : String) : m α :=
labels p (Dlist.singleton lbl)

infixr ` <?> `:2 := label

@[inline] def hidden (p : m α) : m α :=
labels p Dlist.Empty

/--
`try p` behaves like `p`, but it pretends `p` hasn't
consumed any input when `p` fails.

It is useful for implementing infinite lookahead.
The Parser `try p <|> q` will try `q` even when
`p` has consumed input.

It is also useful for specifying both the lexer and Parser
together.
```
    (do try (ch 'l' >> ch 'e' >> ch 't'), whitespace, ...)
    <|>
    ...
```
Without the `try` Combinator we will not be able to backtrack on the `let` keyword.
-/

@[inline] def try (p : m α) : m α :=
map (λ m' inst β p, @ParsecT.try m' inst μ β p) p

/-- Parse `p` without consuming any input. -/
@[inline] def lookahead (p : m α) : m α :=
map (λ m' inst β p, @ParsecT.lookahead m' inst μ β p) p

/-- Faster version of `notFollowedBy (satisfy p)` -/
@[inline] def notFollowedBySat (p : Char → Bool) : m unit :=
do it ← leftOver,
   if !it.hasNext then pure ()
   else let c := it.curr in
       if p c then error (repr c)
       else pure ()

def eoiError (it : Iterator) : Result μ α :=
Result.error { it := it, unexpected := "end of input", custom := default _ } ff

def curr : m Char :=
String.Iterator.curr <$> leftOver

@[inline] def cond (p : Char → Bool) (t : m α) (e : m α) : m α :=
mcond (p <$> curr) t e

/--
If the next character `c` satisfies `p`, then
update Position and return `c`. Otherwise,
generate error Message with current Position and character. -/
@[inline] def satisfy (p : Char → Bool) : m Char :=
do it ← leftOver,
   if !it.hasNext then error "end of input"
   else let c := it.curr in
       if p c then lift $ λ _, Result.ok c it.next none
       else error (repr c)

def ch (c : Char) : m Char :=
satisfy (= c)

def alpha : m Char :=
satisfy Char.isAlpha

def digit : m Char :=
satisfy Char.isDigit

def upper : m Char :=
satisfy Char.isUpper

def lower : m Char :=
satisfy Char.isLower

def any : m Char :=
satisfy (λ _, True)

private def strAux : Nat → Iterator → Iterator → Option Iterator
| 0     _    it := some it
| (n+1) sIt it :=
  if it.hasNext ∧ sIt.curr = it.curr then strAux n sIt.next it.next
  else none

/--
`str s` parses a sequence of elements that match `s`. Returns the parsed String (i.e. `s`).
This Parser consumes no input if it fails (even if a partial match).
Note: The behaviour of this Parser is different to that the `String` Parser in the ParsecT Μ M Haskell library,
as this one is all-or-nothing.
-/
def strCore (s : String) (ex : Dlist String) : m String :=
if s.isEmpty then pure ""
else lift $ λ it, match strAux s.length s.mkIterator it with
  | some it' := Result.ok s it' none
  | none     := Result.error { it := it, expected := ex, custom := none } ff

@[inline] def str (s : String) : m String :=
strCore s (Dlist.singleton (repr s))

private def takeAux : Nat → String → Iterator → Result μ String
| 0     r it := Result.ok r it none
| (n+1) r it :=
  if !it.hasNext then eoiError it
  else takeAux n (r.push (it.curr)) it.next

/-- Consume `n` characters. -/
def take (n : Nat) : m String :=
if n = 0 then pure ""
else lift $ takeAux n ""

private def mkStringResult (r : String) (it : Iterator) : Result μ String :=
if r.isEmpty then Result.mkEps r it
else Result.ok r it none

@[specialize]
private def takeWhileAux (p : Char → Bool) : Nat → String → Iterator → Result μ String
| 0     r it := mkStringResult r it
| (n+1) r it :=
  if !it.hasNext then mkStringResult r it
  else let c := it.curr in
       if p c then takeWhileAux n (r.push c) it.next
       else mkStringResult r it

/--
Consume input as long as the predicate returns `tt`, and return the consumed input.
This Parser does not fail. It will return an Empty String if the predicate
returns `ff` on the current character. -/
@[specialize] def takeWhile (p : Char → Bool) : m String :=
lift $ λ it, takeWhileAux p it.remaining "" it

@[specialize] def takeWhileCont (p : Char → Bool) (ini : String) : m String :=
lift $ λ it, takeWhileAux p it.remaining ini it

/--
Consume input as long as the predicate returns `tt`, and return the consumed input.
This Parser requires the predicate to succeed on at least once. -/
@[specialize] def takeWhile1 (p : Char → Bool) : m String :=
do c ← satisfy p,
   takeWhileCont p (toString c)

/--
Consume input as long as the predicate returns `ff` (i.e. until it returns `tt`), and return the consumed input.
This Parser does not fail. -/
@[inline] def takeUntil (p : Char → Bool) : m String :=
takeWhile (λ c, !p c)

@[inline] def takeUntil1 (p : Char → Bool) : m String :=
takeWhile1 (λ c, !p c)

private def mkConsumedResult (consumed : Bool) (it : Iterator) : Result μ unit :=
if consumed then Result.ok () it none
else Result.mkEps () it

@[specialize] private def takeWhileAux' (p : Char → Bool) : Nat → Bool → Iterator → Result μ unit
| 0     consumed it := mkConsumedResult consumed it
| (n+1) consumed it :=
  if !it.hasNext then mkConsumedResult consumed it
  else let c := it.curr in
       if p c then takeWhileAux' n tt it.next
       else mkConsumedResult consumed it

/-- Similar to `takeWhile` but it does not return the consumed input. -/
@[specialize] def takeWhile' (p : Char → Bool) : m unit :=
lift $ λ it, takeWhileAux' p it.remaining ff it

/-- Similar to `takeWhile1` but it does not return the consumed input. -/
@[specialize] def takeWhile1' (p : Char → Bool) : m unit :=
satisfy p *> takeWhile' p

/-- Consume zero or more whitespaces. -/
@[noinline] def whitespace : m unit :=
takeWhile' Char.isWhitespace

/-- Shorthand for `p <* whitespace` -/
@[inline] def lexeme (p : m α) : m α :=
p <* whitespace

/-- Parse a numeral in decimal. -/
@[noinline] def num : m Nat :=
String.toNat <$> (takeWhile1 Char.isDigit)

/-- Succeed only if there are at least `n` characters left. -/
def ensure (n : Nat) : m unit :=
do it ← leftOver,
   if n ≤ it.remaining then pure ()
   else error "end of input" (Dlist.singleton ("at least " ++ toString n ++ " characters"))

/-- Return the current Position. -/
def pos : m Position :=
String.Iterator.offset <$> leftOver


/-- `notFollowedBy p` succeeds when Parser `p` fails -/
@[inline] def notFollowedBy [MonadExcept (Message μ) m] (p : m α) (msg : String := "input") : m unit :=
do it ← leftOver,
   b ← lookahead $ catch (p *> pure ff) (λ _, pure tt),
   if b then pure () else error msg Dlist.Empty it

def eoi : m unit :=
do it ← leftOver,
   if it.remaining = 0 then pure ()
   else error (repr it.curr) (Dlist.singleton ("end of input"))

@[specialize] def many1Aux [Alternative m] (p : m α) : Nat → m (List α)
| 0     := do a ← p, pure [a]
| (n+1) := do a ← p,
              as ← (many1Aux n <|> pure []),
              pure (a::as)

@[specialize] def many1 [Alternative m] (p : m α) : m (List α) :=
do r ← remaining, many1Aux p r

@[specialize] def many [Alternative m] (p : m α) : m (List α) :=
many1 p <|> pure []

@[specialize] def many1Aux' [Alternative m] (p : m α) : Nat → m unit
| 0     := p *> pure ()
| (n+1) := p *> (many1Aux' n <|> pure ())

@[inline] def many1' [Alternative m] (p : m α) : m unit :=
do r ← remaining, many1Aux' p r

@[specialize] def many' [Alternative m] (p : m α) : m unit :=
many1' p <|> pure ()

@[specialize] def sepBy1 [Alternative m] (p : m α) (sep : m β) : m (List α) :=
(::) <$> p <*> many (sep *> p)

@[specialize] def SepBy [Alternative m] (p : m α) (sep : m β) : m (List α) :=
sepBy1 p sep <|> pure []

@[specialize] def fixAux [Alternative m] (f : m α → m α) : Nat → m α
| 0     := error "fixAux: no progress"
| (n+1) := f (fixAux n)

@[specialize] def fix [Alternative m] (f : m α → m α) : m α :=
do n ← remaining, fixAux f (n+1)

@[specialize] def foldrAux [Alternative m] (f : α → β → β) (p : m α) (b : β) : Nat → m β
| 0     := pure b
| (n+1) := (f <$> p <*> foldrAux n) <|> pure b

/-- Matches zero or more occurrences of `p`, and folds the Result. -/
@[specialize] def foldr [Alternative m] (f : α → β → β) (p : m α) (b : β) : m β :=
do it ← leftOver,
   foldrAux f p b it.remaining

@[specialize] def foldlAux [Alternative m] (f : α → β → α) (p : m β) : α → Nat → m α
| a 0     := pure a
| a (n+1) := (do x ← p, foldlAux (f a x) n) <|> pure a

/-- Matches zero or more occurrences of `p`, and folds the Result. -/
@[specialize] def foldl [Alternative m] (f : α → β → α) (a : α) (p : m β) : m α :=
do it ← leftOver,
   foldlAux f p a it.remaining

def unexpected (msg : String) : m α :=
error msg

def unexpectedAt (msg : String) (it : Iterator) : m α :=
error msg Dlist.Empty it

/- Execute all parsers in `ps` and return the Result of the longest parse(s) if any,
   or else the Result of the furthest error. If there are two parses of
   equal length, the first parse wins. -/
@[specialize]
def longestMatch [MonadExcept (Message μ) m] (ps : List (m α)) : m (List α) :=
do it ← leftOver,
   r ← ps.mfoldr (λ p (r : Result μ (List α)),
     lookahead $ catch
       (do
         a ← p,
         it ← leftOver,
         pure $ match r with
         | Result.ok as it' none := if it'.offset > it.offset then r
             else if it.offset > it'.offset then Result.ok [a] it none
             else Result.ok (a::as) it none
         | _                     := Result.ok [a] it none)
       (λ msg, pure $ match r with
           | Result.error msg' _ := if msg'.it.offset > msg.it.offset then r
             else if msg.it.offset > msg'.it.offset then Result.error msg tt
             else Result.error (merge msg msg') (msg.it.offset > it.offset)
           | _ := r))
    ((error "longestMatch: Empty List" : Parsec _ _) it),
    lift $ λ _, r

@[specialize]
def observing [MonadExcept (Message μ) m] (p : m α) : m (Except (Message μ) α) :=
catch (Except.ok <$> p) $ λ msg, pure (Except.error msg)

end MonadParsec

namespace MonadParsec
open ParsecT
variables {m : Type → Type} [Monad m] [MonadParsec unit m] {α β : Type}

end MonadParsec

namespace ParsecT
open MonadParsec
variables {m : Type → Type} [Monad m] {α β : Type}

def parse (p : ParsecT μ m α) (s : String) (fname := "") : m (Except (Message μ) α) :=
run p s fname

def parseWithEoi (p : ParsecT μ m α) (s : String) (fname := "") : m (Except (Message μ) α) :=
run (p <* eoi) s fname

def parseWithLeftOver (p : ParsecT μ m α) (s : String) (fname := "") : m (Except (Message μ) (α × Iterator)) :=
run (Prod.mk <$> p <*> leftOver) s fname

end ParsecT

def Parsec.parse {α : Type} (p : Parsec μ α) (s : String) (fname := "") : Except (Message μ) α :=
ParsecT.parse p s fname

end Parser
end Lean
