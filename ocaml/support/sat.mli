(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A general purpose SAT solver. *)

module type USER =
  sig
    type t
    val to_string : t -> string
    val unused : t      (* Any value of type t; just to make the compiler happy *)
  end

module MakeSAT :
  functor (User : USER) ->
    sig
      (** A SAT problem consists of a set of variables and a set of clauses which must be satisfied. *)
      type sat_problem

      type var
      val add_variable : sat_problem -> User.t -> var
      type var_value = True | False | Undecided

      (** A literal is either a variable (e.g. [A]) or a negated variable ([not A]).
          A variable is equal to its corresponding positive literal (so [var] is really
          a subset of [lit]). *)
      type lit = var
      val neg : lit -> lit
      val var_of_lit : lit -> var

      (** A clause is a boolean expression made up of literals. e.g. [A and B and not(C)] *)
      type clause

      (** {2 Setting up the problem.} *)

      (* Create a problem. *)
      val create : unit -> sat_problem

      (** Get the assignment for this variable in the discovered solution. *)
      type solution = var -> bool

      (** Indicate that the problem is unsolvable, before even starting. This is a convenience
          feature so that clients don't need a separate code path for problems they discover
          during setup vs problems discovered by the solver. *)
      val impossible : sat_problem -> unit -> unit

      type added_result = AddedFact of bool | AddedClause of clause
      (** Add a clause requiring at least one literal to be [True]. e.g. [A or B or not(C)].
          [reason] is used in debug messages. *)
      val at_least_one : sat_problem -> ?reason:string -> lit list -> unit

      (** If the first variable is true, at least one of the others must be.
          [implies p a bs] is equivalent to [at_least_one p ((neg a) :: bs)].
          [reason] is used in debug messages. *)
      val implies : sat_problem -> ?reason:string -> lit -> lit list -> unit

      type at_most_one_clause
      (** Add a clause preventing more than one literal in the list from being [True]. *)
      val at_most_one : sat_problem -> lit list -> at_most_one_clause

      (** [run_solver decider] tries to solve the SAT problem. It simplifies it as much as possible first. When it
          has two paths which both appear possible, it calls [decider ()] to choose which to explore first. If this
          leads to a solution, it will be used. If not, the other path will be tried. If [decider] returns [None],
          we try setting the remaining variables to [False] ([decider] will not be called again unless we backtrack).
          Use this to tidy up at the end, when you no longer care about the order.
          @return true on success. *)
      val run_solver : sat_problem -> (unit -> lit option) -> solution option

      (** Return the first literal in the list whose value is [Undecided], or [None] if they're all decided.
          The decider function may find this useful. *)
      val get_best_undecided : at_most_one_clause -> lit option

      (** Return the selected literal, if any. *)
      val get_selected : at_most_one_clause -> lit option

      (** {2 Debugging} *)

      type reason = Clause of clause | External of string
      type var_info = {
        mutable value : var_value;
        mutable reason : reason option;
        mutable level : int;
        mutable undo : (lit -> unit) list;
        obj : User.t;
      }

      val string_of_clause : clause -> string
      val string_of_reason : reason -> string
      val string_of_value : var_value -> string
      val string_of_var : var_info -> string
      val name_lit : sat_problem -> lit -> string
      val string_of_lits : sat_problem -> lit list -> string
      val lit_value : sat_problem -> lit -> var_value
      val get_varinfo_for_lit : sat_problem -> lit -> var_info
    end
