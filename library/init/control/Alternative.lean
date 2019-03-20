/-
Copyright (c) 2016 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Leonardo de Moura
-/
prelude
import init.core init.control.applicative
universes u v

class HasOrelse (f : Type u → Type v) : Type (max (u+1) v) :=
(orelse  : Π {α : Type u}, f α → f α → f α)

infixr ` <|> `:2 := HasOrelse.orelse

class Alternative (f : Type u → Type v) extends Applicative f, HasOrelse f : Type (max (u+1) v) :=
(failure : Π {α : Type u}, f α)

section
variables {f : Type u → Type v} [Alternative f] {α : Type u}

@[inline] def failure : f α :=
Alternative.failure f

@[inline] def guard {f : Type → Type v} [Alternative f] (p : Prop) [Decidable p] : f unit :=
if p then pure () else failure

@[inline] def assert {f : Type → Type v} [Alternative f] (p : Prop) [Decidable p] : f (Inhabited p) :=
if h : p then pure ⟨h⟩ else failure

/- Later we define a coercion from Bool to Prop, but this version will still be useful.
   Given (t : tactic Bool), we can write t >>= guardb -/
@[inline] def guardb {f : Type → Type v} [Alternative f] : Bool → f unit
| tt := pure ()
| ff := failure

@[inline] def optional (x : f α) : f (Option α) :=
some <$> x <|> pure none

end
