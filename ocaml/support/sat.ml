(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A general purpose SAT solver. *)

(** The design of this solver is very heavily based on the one described in
   the MiniSat paper "An Extensible SAT-solver [extended version 1.2]"
   http://minisat.se/Papers.html

   The main differences are:

   - We care about which solution we find (not just "satisfiable" or "not").
   - We take care to be deterministic (always select the same versions given
     the same input). We do not do random restarts, etc.
   - We add an at_most_one_clause (the paper suggests this in the Excercises, and
     it's very useful for our purposes).
 *)

let debug = false

module type USER =
  sig
    type t
    val to_string : t -> string
    val unused : t
  end

module MakeSAT(User : USER) =
  struct
    let (@@) = Common.(@@)

    type var_value = True | False | Undecided

    let log_debug fmt =
      let do_print msg =
        print_endline ("sat: " ^ msg) in
      Printf.ksprintf do_print fmt

    type lit = int
    type var = int
    type solution = var -> bool

    class type clause =
      object
        (* [lit] is now [True]. Add any new deductions.
           @return false if there is a conflict. *)
        method propagate : lit -> bool

        (** Why are we causing a conflict?
            @return a list of literals which caused the problem by all being True. *)
        method calc_reason : unit -> lit list

        (** Which literals caused [lit] to have its current value?
            @return a list of literals which caused the problem by all being True. *)
        method calc_reason_for : lit -> lit list

        (** For debugging *)
        method to_string : unit -> string
      end

    (** The reason why a literal is set. *)
    type reason =
      | Clause of clause        (* the clause that caused this literal to be true *)
      | External of string      (* set externally (input fact or decider choice) *)

    (** Using an array of VarInfo objects is less efficient than using multiple arrays, but
        easier for me to understand. *)
    type var_info = {
      mutable value : var_value;                          (* True/False/Undecided *)
      mutable reason : reason option;                     (* The constraint that implied our value, if True or False *)
      mutable level: int;                                 (* The decision level at which we got a value (when not Undecided) *)
      mutable undo: (lit -> unit) list;                   (* Functions to call if we become unbound (by backtracking) *)
      obj: User.t;                                        (* The object this corresponds to (for our caller and for debugging) *)
    }

    let make_var obj = {
        value = Undecided;
        reason = None;
        level = -1;
        undo = [];
        obj;
      }

    module WatchElement =
      struct
        type t = clause Queue.t
        let undefined = Queue.create ()
      end

    module VarInfoElement =
      struct
        type t = var_info
        let undefined = make_var User.unused
      end

    module WatchArray = Dynarray.Make(WatchElement)
    module VarInfoArray = Dynarray.Make(VarInfoElement)

    type sat_problem = {
      (* Propagation *)
      watches : WatchArray.t;       (* watches[2i,2i+1] = constraints to check when literal[i] becomes True/False *)
      propQ : lit Queue.t;	        (* propagation queue *)

      (* Assignments *)
      assigns : VarInfoArray.t;	(* the current values of the variables *)
      mutable trail : lit list;	(* order of assignments, most recent first *)
      mutable trail_lim : int list; (* decision levels (len(trail) at each decision) *)

      mutable toplevel_conflict : bool;

      mutable set_to_false : bool;     (* we are finishing up by setting everything else to False *)
    }

    let string_of_reason = function
      | Clause clause -> clause#to_string ()
      | External msg -> msg

    (* Variables are numbered from 0
       Literals have the same number as the corresponding variable,
       except that for negatives they are (-1-v):

       Variable    Literal     not(Literal)
       0	       0	   -1
       1	       1	   -2
     *)
    let neg lit = -1 - lit

    let var_of_lit lit = if lit >= 0 then lit else neg lit

    let watch_index lit =
        if lit >= 0 then lit * 2
        else neg lit * 2 + 1

    let remove_duplicates lits =
      let seen = Hashtbl.create (List.length lits) in

      let rec find_unique = function
        | [] -> []
        | (x::xs) when Hashtbl.mem seen x -> find_unique xs
        | (x::xs) ->
            Hashtbl.add seen x true;
            x :: find_unique xs in

      find_unique lits

    let swap arr i j =
      let (first, second) = (arr.(i), arr.(j)) in
      arr.(i) <- second;
      arr.(j) <- first

    let string_of_value = function
      | True -> "true"
      | False -> "false"
      | Undecided -> "undecided"

    let string_of_var info =
      Printf.sprintf "%s=%s" (User.to_string info.obj) (string_of_value info.value)

    exception ConflictingClause of clause
    exception SolveDone of solution option

    type added_result =
      | AddedFact of bool                   (* Result of enqueing the new fact *)
      | AddedClause of clause

    let create () =
      if debug then log_debug "--- new SAT problem ---";
      {
        watches = WatchArray.make ();
        propQ = Queue.create ();

        assigns = VarInfoArray.make ();
        trail = [];
        trail_lim = [];

        toplevel_conflict = false;
        set_to_false = false;
      }

    (* For nicer if debug then log_debug messages *)
    let name_lit problem lit =
      if lit >= 0 then
        User.to_string (VarInfoArray.get lit problem.assigns).obj
      else
        let info = VarInfoArray.get (neg lit) problem.assigns in
        Printf.sprintf "not(%s)" (User.to_string info.obj)

    let string_of_lits problem lits =
      "[" ^ (String.concat ", " (List.map (name_lit problem) lits)) ^ "]"

    let lit_value (problem:sat_problem) lit =
      if lit >= 0 then (
        (VarInfoArray.get lit problem.assigns).value
      ) else (
        match (VarInfoArray.get (neg lit) problem.assigns).value with
        | Undecided -> Undecided
        | True -> False
        | False -> True
      )

    let get_varinfo_for_lit problem lit =
      VarInfoArray.get (var_of_lit lit) problem.assigns

    let get_decision_level problem = List.length problem.trail_lim

    let add_variable problem obj : var =
      (* if debug then log_debug "add_variable('%s')" obj; *)
      let index = problem.assigns.VarInfoArray.n in

      WatchArray.add (Queue.create ()) problem.watches;          (* Add watch lists for X and not(X) *)
      WatchArray.add (Queue.create ()) problem.watches;

      VarInfoArray.add (make_var obj) problem.assigns;
      index

    (* [lit] is now [True].
       [reason] is the clause that is asserting this.
       @return [false] if this immediately causes a conflict. *)
    let enqueue problem lit reason =
      if debug then log_debug "enqueue: %s (%s)" (name_lit problem lit) (string_of_reason reason);
      let old_value = lit_value problem lit in
      match old_value with
      | False -> false      (* Conflict *)
      | True -> true        (* Already set (shouldn't happen) *)
      | Undecided ->
          let var_info = get_varinfo_for_lit problem lit in
          var_info.value <- if lit < 0 then False else True;
          var_info.level <- get_decision_level problem;
          var_info.reason <- Some reason;

          problem.trail <- lit :: problem.trail;
          Queue.add lit problem.propQ;

          true

    (* Pop most recent assignment from [trail] *)
    let undo_one problem =
      match problem.trail with
      | [] -> assert false
      | lit :: rest ->
          (* if debug then log_debug "(pop %s)" (name_lit problem lit); *)
          let var_info = get_varinfo_for_lit problem lit in
          var_info.value <- Undecided;
          var_info.reason <- None;
          var_info.level <- -1;
          problem.trail <- rest;

          while var_info.undo <> [] do
            let cb = List.hd var_info.undo in
            var_info.undo <- List.tl var_info.undo;
            cb lit
          done

    let cancel problem =
      let n_this_level = List.length problem.trail - (List.hd problem.trail_lim) in
      if debug then log_debug "backtracking from level %d (%d assignments)" (get_decision_level problem) n_this_level;
      for _i = 1 to n_this_level do
        undo_one problem;
      done;
      problem.trail_lim <- List.tl problem.trail_lim

    let cancel_until problem level =
      while get_decision_level problem > level do
        cancel problem
      done

    (** Process the propQ.
        Returns None when done, or the clause that caused a conflict. *)
    let propagate problem =
      (* if debug then log_debug "propagate: queue length = %d" (Queue.length problem.propQ); *)
      try
        while not (Queue.is_empty problem.propQ) do
          let lit = Queue.take problem.propQ in
          let wi = watch_index lit in
          let old_watches = WatchArray.get wi problem.watches in
          WatchArray.set wi (Queue.create ()) problem.watches;

          (* if debug then log_debug "%s -> True : watches: %d" (name_lit problem lit) (Queue.length old_watches); *)

          (* Notifiy all watchers *)
          while not (Queue.is_empty old_watches) do
            let clause = Queue.take old_watches in
            if not (clause#propagate lit) then (
              (* Conflict *)

              (* Re-add remaining watches *)
              Queue.transfer old_watches (WatchArray.get wi problem.watches);

              (* No point processing the rest of the queue as
                 we'll have to backtrack now. *)
              Queue.clear problem.propQ;

              raise (ConflictingClause clause)
            )
          done
        done;
        None
      with ConflictingClause c -> Some c

    let impossible problem () =
      problem.toplevel_conflict <- true

    (* Call [clause#propagate lit] when lit becomes True *)
    let watch_lit problem lit clause =
      (* if debug then log_debug "%s is watching for %s to become True" (clause#to_string ()) (name_lit problem lit); *)
      Queue.add clause (WatchArray.get (watch_index lit) problem.watches)

    class union_clause problem lits =
      object (self : #clause)
        (* Try to infer new facts.
           We can do this only when all of our literals are False except one,
           which is undecided. That is,
             False... or X or False... = True  =>  X = True

           To get notified when this happens, we tell the solver to
           watch two of our undecided literals. Watching two undecided
           literals is sufficient. When one changes we check the state
           again. If we still have two or more undecided then we switch
           to watching them, otherwise we propagate.

           Returns false on conflict. *)
        method propagate lit =
          (* [neg lit] has just become False *)

          (*if debug then log_debug("%s: noticed %s has become False" % (self, self.solver.name_lit(neg(lit)))) *)

          (* For simplicity, only handle the case where self.lits[1]
             is the one that just got set to False, so that:
             - value[lits[0]] = Undecided | True
             - value[lits[1]] = False
             If it's the other way around, just swap them before we start. *)
          if lits.(0) = neg lit then swap lits 0 1;

          if lit_value problem lits.(0) = True then (
            (* We're already satisfied. Do nothing. *)
            watch_lit problem lit (self :> clause);
            true
          ) else (
            assert (lit_value problem lits.(1) = False);

            (* Find a new literal to watch now that lits[1] is resolved, *)
            (* swap it with lits[1], and start watching it. *)
            let rec find_not_false i =
              if i = Array.length lits then (
                (* Only lits[0], is now undefined, so set it to True. *)
                watch_lit problem lit (self :> clause);
                enqueue problem lits.(0) (Clause (self :> clause))
              ) else (
                match lit_value problem lits.(i) with
                | Undecided | True ->
                    (* If it's True then we've already done our job,
                       so this means we don't get notified unless we backtrack, which is fine. *)
                    swap lits 1 i;
                    watch_lit problem (neg lits.(1)) (self :> clause);
                    true
                | False -> find_not_false (i + 1)
              ) in
            find_not_false 2
          )

        (* We can only cause a conflict if all our lits are False, so they're all the cause.
           e.g. if we are "A or B or not(C)" then "not(A) and not(B) and C" causes a conflict.
         *)
        method calc_reason () = List.map neg (Array.to_list lits)

        (** Which literals caused [lit] to have its current value? *)
        method calc_reason_for lit =
          assert (lit = lits.(0));
          (* The cause is everything except lit. *)
          let rec get_cause i =
            if i = Array.length lits then []
            else (
              let l = lits.(i) in
              if l = lit then get_cause (i + 1)
              else neg l :: get_cause (i + 1)
            ) in
          get_cause 0

        method to_string () =
          Printf.sprintf "<some: %s>" (String.concat ", " (Array.to_list (Array.map (name_lit problem) lits)))
      end

    exception Conflict

    (* If one literal in the list becomes True, all the others must be False.
       Preferred literals should be listed first. *)
    class at_most_one_clause problem lits =
      (* The single literal from our set that is True.
         We store this explicitly because the decider needs to know quickly. *)
      let current = ref None in
      let lit_val = lit_value problem in
      object (self : #clause)
        method propagate lit =
          (* Re-add ourselves to the watch list.
            (we we won't get any more notifications unless we backtrack,
            in which case we'd need to get back on the list anyway) *)
          watch_lit problem lit (self :> clause);

          (* value[lit] has just become true *)
          assert (lit_val lit = True);

          (* if debug then log_debug("%s: noticed %s has become True" % (self, self.solver.name_lit(lit))) *)

          (* If we already propagated successfully when the first
             one was set then we set all the others to false and
             anyone trying to set one true will get rejected. And
             if we didn't propagate yet, current will still be
             None, even if we now have a conflict (which we'll
             detect below). *)
          assert (!current = None);

          current := Some lit;

          (* If we later backtrack, unset current *)
          let undo lit =
            if debug then log_debug "(backtracking: no longer selected %s)" (name_lit problem lit);
            assert (Some lit = !current);
            current := None in
          let var_info = get_varinfo_for_lit problem lit in
          var_info.undo <- undo :: var_info.undo;

          try
            (* We set all other literals to False. *)
            ListLabels.iter lits ~f:(fun l ->
              match lit_val l with
              | True when l <> lit ->
                  (* Due to queuing, we might get called with current = None
                     and two versions already selected. *)
                  if debug then log_debug "CONFLICT: already selected %s" (name_lit problem l);
                  raise Conflict
              | Undecided ->
                (* Since one of our lits is already true, all unknown ones
                   can be set to False. *)
                if not @@ enqueue problem (neg l) (Clause (self :> clause)) then (
                  if debug then log_debug "CONFLICT: enqueue failed for %s" (name_lit problem (neg l));
                  raise Conflict
                )
              | _ -> ()
            );
            true
          with Conflict -> false

        (** If we caused a conflict, it's because two of our literals became true. *)
        method calc_reason () =
          (* Find two True literals *)
          let rec find_two found = function
            | [] -> assert false      (* Don't know why! *)
            | (x::xs) when lit_val x <> True -> find_two found xs
            | (x::xs) ->
                match found with
                | None -> find_two (Some x) xs
                | Some first -> [first; x]
          in
          find_two None lits

        (** Which literals caused [lit] to have its current value? *)
        method calc_reason_for lit =
          (* Find the True literal. Any true literal other than [lit] would do. *)
          [List.find (fun l -> l <> lit && lit_val l = True) lits]

        method best_undecided () =
          (* if debug then log_debug "best_undecided: %s" (string_of_lits problem lits); *)
          try Some (List.find (fun l -> lit_val l = Undecided) lits)
          with Not_found -> None

        method get_selected () =
          !current

        method to_string () =
          Printf.sprintf "<at most one: %s>" (string_of_lits problem lits)
      end

    let get_best_undecided clause = clause#best_undecided ()
    let get_selected clause = clause#get_selected ()

    let string_of_clause clause = clause#to_string ()

    (* Returns the new clause if one was added, [AddedFact true] if none was added
       because this clause is trivially True, or [AddedFact false] if the clause
       caused a conflict. *)
    let internal_at_most_one problem lits ~learnt ~reason =
      match lits with
      | [] -> assert false
      | [lit] ->
          (* A clause with only a single literal is represented
             as an assignment rather than as a clause. *)
          AddedFact (enqueue problem lit reason)
      | lits ->
          let lits = Array.of_list lits in
          let clause = new union_clause problem lits in

          if learnt then (
            (* lits[0] is Undecided because we just backtracked.
               Start watching the next literal that we will backtrack over. *)
            let best_level = ref (-1) in
            let best_i = ref 1 in
            for i = 0 to (Array.length lits) - 1 do
              let lit = lits.(i) in
              let level = (get_varinfo_for_lit problem lit).level in
              if level > !best_level then (
                best_level := level;
                best_i := i
              )
            done;
            swap lits 1 !best_i;
          );

          (* Watch the first two literals in the clause (both must be
             undefined at this point). *)
          let watch i = watch_lit problem (neg lits.(i)) clause in
          watch 0;
          watch 1;

          AddedClause clause

    (** Public interface. Only used before the solve starts. *)
    let at_least_one problem ?(reason="input fact") lits =
      if List.length lits = 0 then (
        problem.toplevel_conflict <- true;
      ) else (
        (* if debug then log_debug "at_least_one(%s)" (string_of_lits problem lits); *)

        if List.exists (fun l -> (lit_value problem l) = True) lits then (
          (* Trivially true already if any literal is True. *)
          ()
        ) else (
          let seen = Hashtbl.create (List.length lits) in

          let rec simplify unique = function
            | [] -> Some unique
            | (x::_) when Hashtbl.mem seen (neg x) -> None                (* X or not(X) is always True *)
            | (x::xs) when Hashtbl.mem seen x -> simplify unique xs       (* Skip duplicates *)
            | (x::xs) when lit_value problem x = False -> simplify unique xs (* Skip values known to be False *)
            | (x::xs) ->
                Hashtbl.add seen x true;
                simplify (x :: unique) xs in

          (* At this point, [unique] contains only [Undefined] literals. *)

          match simplify [] lits with
          | None -> ()
          | Some [] -> problem.toplevel_conflict <- true      (* Everything in the list was False *)
          | Some unique ->
              if internal_at_most_one problem unique ~learnt:false ~reason:(External reason) = AddedFact false then
                problem.toplevel_conflict <- true;
        )
      )

    let implies problem ?reason first rest = at_least_one problem ?reason @@ (neg first) :: rest

    let at_most_one problem lits =
      assert (List.length lits > 0);

      (* if debug then log_debug "at_most_one(%s)" (string_of_lits problem lits); *)

      (* If we have zero or one literals then we're trivially true
         and not really needed for the solve. However, Zero Install
         monitors these objects to find out what was selected, so
         keep even trivial ones around for that.
         *)
      (*if len(lits) < 2: *)
      (*	return True	# Trivially true *)

      (* Ensure no duplicates *)
      assert (List.length (remove_duplicates lits) = List.length lits);

      (* Ignore any literals already known to be False.
         If any are True then they're enqueued and we'll process them
         soon. *)
      let lits = List.filter (fun l -> lit_value problem l <> False) lits in

      let clause = new at_most_one_clause problem lits in

      List.iter (fun l -> watch_lit problem l (clause :> clause)) lits;

      clause

    let analyse problem original_cause =
      (* After trying some assignments, we've discovered a conflict.
         e.g.
         - we selected A then B then C
         - from A, B, C we got X, Y
         - we have a rule (original_cause): not(A) or not(X) or not(Y)

         The simplest thing to do would be:
         1. add the rule "not(A) or not(B) or not(C)"
         2. unassign C

         Then we'd deduce not(C) and we could try something else.
         However, that would be inefficient. We want to learn a more
         general rule that will help us with the rest of the problem.

         We take the clause that caused the conflict (original_cause)
         and ask it for its cause. In this case:

          A and X and Y => conflict

         Since X and Y followed logically from A, B, C there's no
         point learning this rule; we need to know to avoid A, B, C
         *before* choosing C. We ask the two variables deduced at the
         current level (X and Y) what caused them, and work backwards.
         e.g.

          X: A and C => X
          Y: C => Y

         Combining these, we get the cause of the conflict in terms of
         things we knew before the current decision level:

          A and X and Y => conflict
          A and (A and C) and (C) => conflict
          A and C => conflict

         We can then learn (record) the more general rule:

          not(A) or not(C)

         Then, in future, whenever A is selected we can remove C and
         everything that depends on it from consideration.
      *)
      let learnt = ref [] in	        (* The general rule we're learning *)
      let btlevel = ref 0 in		(* The deepest decision in learnt *)
      let seen = Hashtbl.create 10 in	(* The variables involved in the conflict *)

      let counter = ref 0 in                (* The number of pending variables to check *)

      (* [outcome] was caused by the literals [p_reason] all being True. Follow the
         causes back, adding anything decided before this level to [learnt]. When
         we get bored, return the literal we were processing at the time. *)
      let rec follow_causes p_reason outcome =
        if debug then log_debug "because %s => %s" (String.concat " and " (List.map (name_lit problem) p_reason)) outcome;

        (* p_reason is in the form (A and B and ...) *)

        (* Check each of the variables in p_reason that we haven't
           already considered:
           - if the variable was assigned at the current level,
             mark it for expansion
           - otherwise, add it to learnt *)

        ListLabels.iter p_reason ~f:(fun lit ->
          let var = var_of_lit lit in
          if not (Hashtbl.mem seen var) then (
            Hashtbl.add seen var true;
            let var_info = get_varinfo_for_lit problem lit in
            if var_info.level = get_decision_level problem then (
              (* We deduced this var since the last decision.
                 It must be in [trail], so we'll get to it
                 soon. Remember not to stop until we've processed it. *)
              (* if debug then log_debug "(will look at %s soon)" (name_lit problem lit); *)
              counter := !counter + 1
            ) else if var_info.level > 0 then (
              (* We won't expand lit, just remember it.
                 (we could expand it if it's not a decision, but
                 apparently not doing so is useful) *)
              (* if debug then log_debug "Can't follow %s past a decision point" (name_lit problem lit); *)
              learnt := neg lit :: !learnt;
              btlevel := max !btlevel (var_info.level)
            ) (* else if debug then log_debug "Input fact: %s" (name_lit problem lit) *)
          ) (* else we already considered the cause of this assignment *)
        );

        (* At this point, counter is the number of assigned
           variables in [trail] at the current decision level that
           we've seen. That is, the number left to process. Pop
           the next one off [trail] (as well as any unrelated
           variables before it; everything up to the previous
           decision has to go anyway). *)

        (* On the first time round the loop, we must find the
           conflict depends on at least one assignment at the
           current level. Otherwise, simply setting the decision
           variable caused a clause to conflict, in which case
           the clause should have asserted not(decision-variable)
           before we ever made the decision.
           On later times round the loop, [counter] was already >
           0 before we started iterating over [p_reason]. *)
        assert (!counter > 0);

        (* Pop assignments until we find one we care about. *)
        let rec next_interesting () =
          let lit = List.hd problem.trail in
          let var = var_of_lit lit in
          let var_info = get_varinfo_for_lit problem lit in
          let reason = var_info.reason in
          undo_one problem;
          if not (Hashtbl.mem seen var) then (
            (* if debug then log_debug "(irrelevant: %s)" (name_lit problem lit); *)
            next_interesting ();
          ) else (
            (reason, lit)
          ) in
        let (reason, p) = next_interesting () in
        (* [reason] is the reason why [p] is True (i.e. it enqueued it). *)
        (* [p] is the literal we want to expand now. *)

        counter := !counter - 1;

        if !counter > 0 then (
          let cause = (match reason with
          | Some (Clause c) -> c
          | Some (External msg) -> failwith msg   (* Can't happen *)
          | None -> failwith "No reason!"         (* Can't happen *)
          ) in
          let p_reason = cause#calc_reason_for p in
          let outcome = name_lit problem p in
          if debug then log_debug "why did %s lead to %s?" (cause#to_string ()) outcome;
          follow_causes p_reason outcome
        ) else (
          (* If counter = 0 then we still have one more
             literal (p) at the current level that we
             could expand. However, apparently it's best
             to leave this unprocessed (says the minisat
             paper). *)
          p
        ) in

      (* Start with all the literals involved in the conflict. *)
      if debug then log_debug "why did %s lead to conflict?" (original_cause#to_string ());
      let p = follow_causes (original_cause#calc_reason ()) "conflict" in
      assert (!counter = 0);

      (* p is the literal we decided to stop processing on. It's either
         a derived variable at the current level, or the decision that
         led to this level. Since we're not going to expand it, add it
         directly to the learnt clause. *)
      let learnt = neg p :: !learnt in

      if debug then log_debug "learnt: %s" (String.concat " or " (List.map (name_lit problem) learnt));

      (learnt, !btlevel)

    let get_assignment solution var =
      assert (var >= 0);
      match (get_varinfo_for_lit solution var).value with
      | True -> true
      | False -> false
      | Undecided -> assert false

    let run_solver problem decide =
      (* Check whether we detected a trivial problem during setup. *)
      if problem.toplevel_conflict then (
        if debug then log_debug "FAIL: toplevel_conflict before starting solve!";
        None
      ) else (
        try
          while true do
            (* Use logical deduction to simplify the clauses
               and assign literals where there is only one possibility. *)
            match propagate problem with
            | None -> (
                (* No conflicts *)
                (* if debug then log_debug "new state: %s" problem.assigns *)
                match VarInfoArray.find_index (fun info -> info.value = Undecided) problem.assigns with
                | None ->
                    (* Everything is assigned without conflicts *)
                    (* if debug then log_debug "SUCCESS!"; *)
                    raise (SolveDone (Some (get_assignment problem)))
                | Some undecided ->
                  (* Pick a variable and try assigning it one way.
                     If it leads to a conflict, we'll backtrack and
                     try it the other way. *)
                  let lit =
                    if problem.set_to_false then (
                      (* Printf.printf "%s -> false\n" (name_lit problem undecided); *)
                      neg undecided
                    ) else (
                      match decide () with
                      | Some lit -> lit
                      | None ->
                          (* Switch to set_to_false mode (until we backtrack). *)
                          let lit = neg undecided in
                          problem.set_to_false <- true;
                          let var_info = get_varinfo_for_lit problem lit in
                          let undo _ = problem.set_to_false <- false in
                          var_info.undo <- undo :: var_info.undo;
                          (* Printf.printf "%s -> false\n" (name_lit problem undecided); *)
                          lit
                    ) in
                  if debug then log_debug "TRYING: %s" (name_lit problem lit);
                  let old = lit_value problem lit in
                  if (old <> Undecided) then
                    failwith ("Decider chose already-decided variable: " ^ (name_lit problem lit) ^ " was " ^ (string_of_value old));
                  problem.trail_lim <- (List.length problem.trail) :: problem.trail_lim;
                  let r = enqueue problem lit (External "considering") in
                  assert r
            )
            | Some conflicting_clause ->
                if get_decision_level problem = 0 then (
                  if debug then log_debug "FAIL: conflict found at top level";
                  raise (SolveDone None)
                ) else (
                  (* Figure out the root cause of this failure. *)
                  let (learnt, backtrack_level) = analyse problem conflicting_clause in
                  (* We have learnt that something in [learnt] must be True or we get a conflict. *)

                  cancel_until problem backtrack_level;

                  match internal_at_most_one problem learnt ~learnt:true ~reason:(Clause conflicting_clause) with
                  | AddedFact true -> ()
                  | AddedFact false ->
                      (* This is what the Python would do. Perhaps it can't happen? *)
                      let e = enqueue problem (List.hd learnt) (External "conflict!") in
                      assert e;
                  | AddedClause c ->
                      (* Everything except the first literal in learnt is known to
                         be False, so the first must be True. *)
                      let e = enqueue problem (List.hd learnt) (Clause c) in
                      assert e;
                )
          done; failwith "not reached"
        with SolveDone x -> x
      )
  end
