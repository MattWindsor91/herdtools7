(*********************************************************************)
(*                        Herd                                       *)
(*                                                                   *)
(* Luc Maranget, INRIA Paris-Rocquencourt, France.                   *)
(* Jade Alglave, University College London, UK.                      *)
(* John Wickerson, Imperial College London, UK.                      *)
(*                                                                   *)
(*  Copyright 2013 Institut National de Recherche en Informatique et *)
(*  en Automatique and the authors. All rights reserved.             *)
(*  This file is distributed  under the terms yof the Lesser GNU      *)
(*  General Public License.                                          *)
(*********************************************************************)

(** Interpreter for a user-specified model *)

open Printf


module type Config = sig
  val m : AST.pp_t
  val bell : bool (* executing bell file *)
  val bell_fname : string option (* name of bell file if present *)
(* Restricted Model.Config *)
  val showsome : bool
  val debug : bool
  val verbose : int
  val skipchecks : StringSet.t
  val strictskip : bool
(* Show control *)
  val doshow : StringSet.t
  val showraw : StringSet.t
  val symetric : StringSet.t
(* find files *)
  val libfind : string -> string
end

(* Simplified Sem module.
   In effect, the interpreter needs a restricted subset of Sem functionalities:
   set of events, relation on events and that is about all.
   A few utlities are passed as the next "U" argument to functor. *)
module type SimplifiedSem = sig
  module E : sig
    type event

    val pp_eiid : event -> string

    module EventSet : MySet.S
    with type elt = event

    module EventRel : InnerRel.S
    with type elt0 = event
    and module Elts = EventSet
  end

  type test
  type concrete

  type event_set = E.EventSet.t
  type event_rel = E.EventRel.t
  type rel_pp = (string * event_rel) list
end

module Make
    (O:Config)
    (S:SimplifiedSem)    
    (U: sig
      val partition_events : S.event_set -> S.event_set list
      val check_through : bool -> bool
      val pp_failure : S.test -> S.concrete -> string -> S.rel_pp -> unit
    end)
    :
    sig

(* Some constants passed to the interpreter, made open for the
   convenience of uilding them from outside *)
      type ks =
          { id : S.event_rel Lazy.t; unv : S.event_rel Lazy.t;
            evts : S.event_set;  conc : S.concrete; }


(* Initial environment, they differ from internal env, so
   as not to expose the polymorphic argument of teh later *)
      type init_env
      val init_env_empty : init_env
      val add_rels : init_env -> S.event_rel Lazy.t Misc.Simple.bds -> init_env
      val add_sets : init_env -> S.event_set Lazy.t Misc.Simple.bds -> init_env

(* Subset of interpreter state used by the caller *)
      type st_out = {
       out_show : S.rel_pp Lazy.t ;
       out_skipped : StringSet.t ;
       out_flags : Flag.Set.t ;
       out_bell_info :  BellModel.info ;       
      }


(* Interpreter *)

      val interpret :
          S.test ->
            ks ->
              init_env ->
                S.rel_pp Lazy.t ->
                  (st_out -> 'a -> 'a) -> 'a -> 'a
    end
    =
  struct

    let _dbg = false

    let next_id =
      let id = ref 0 in
      fun () -> let r = !id in id := r+1 ; r


(****************************)
(* Convenient abbreviations *)
(****************************)

    module E = S.E
    module W = Warn.Make(O)

(* Check utilities *)
    open AST

    let skip_this_check name = match name with
    | Some name -> StringSet.mem name O.skipchecks
    | None -> false

    let check_through test_type ok = match test_type with
    | Check ->  U.check_through ok
    | UndefinedUnless|Flagged -> ok


    let test2pred t = match t with
    | Acyclic -> E.EventRel.is_acyclic
    | Irreflexive -> E.EventRel.is_irreflexive
    | TestEmpty -> E.EventRel.is_empty

    let test2pred = function
      | Yes t -> test2pred t
      | No t -> fun r -> not (test2pred t r)


(* Generic toplogical order generator *)
    let apply_orders es vb kfail kont res =
      try
        E.EventRel.all_topos_kont es vb
          (fun k res ->
            kont (E.EventRel.order_to_rel k) res) res
      with E.EventRel.Cyclic -> kfail vb

(*  Model interpret *)
    let (prog_txt,(_,_,prog)) = O.m

(* Debug printing *)

    let _debug_proc chan p = fprintf chan "%i" p
    let debug_event chan e = fprintf chan "%s" (E.pp_eiid e)
    let debug_set chan s =
      output_char chan '{' ;
      E.EventSet.pp chan "," debug_event s ;
      output_char chan '}'

    let debug_rel chan r =
      E.EventRel.pp chan ","
        (fun chan (e1,e2) -> fprintf chan "%a -> %a"
            debug_event e1 debug_event e2)
        r

    type ks =
        { id : S.event_rel Lazy.t; unv : S.event_rel Lazy.t;
          evts : S.event_set; conc : S.concrete; }

(* Internal typing *)
    type typ =
      | TEmpty | TEvents | TRel | TTag of string |TClo | TProc | TSet of typ
      | TAnyTag | TTuple of typ list | TKont

    let rec eq_type t1 t2 = match t1,t2 with
    | TEmpty,TSet _ -> Some t2
    | TSet _,TEmpty -> Some t1
    | TAnyTag,TTag _
    | TTag _,TAnyTag -> Some TAnyTag
    | TTag s1,TTag s2 when s1 <> s2 -> Some TAnyTag
    | TSet t1,TSet t2 ->
        begin match eq_type t1 t2 with
        | None -> None
        | Some t -> Some (TSet t)
        end
    | TTuple ts1,TTuple ts2 ->
        Misc.app_opt (fun ts -> TTuple ts) (eq_types ts1 ts2)
    | _,_ -> if t1 = t2 then Some t1 else None

    and eq_types ts1 ts2 = match ts1,ts2 with
    | [],[] -> Some []
    | ([],_::_)|(_::_,[]) -> None
    | t1::ts1,t2::ts2 ->
        begin
          let ts = eq_types ts1 ts2
          and t = eq_type t1 t2 in
          match t,ts with
          | Some t,Some ts -> Some (t::ts)
          | _,_ -> None
        end

    let type_equal t1 t2 = match eq_type t1 t2 with
    | None -> false
    | Some _ -> true

    exception CompError of string
    exception PrimError of string


    let rec pp_typ = function
      | TEmpty -> "{}"
      | TEvents -> "event set"
      | TRel -> "rel"
      | TTag ty -> ty
      | TAnyTag -> "anytag"
      | TClo -> "closure"
      | TProc -> "procedure"
      | TSet elt -> sprintf "%s set" (pp_typ elt)
      | TTuple ts ->
          sprintf "(%s)" (String.concat " * " (List.map pp_typ ts))
      | TKont -> "<kont>"

    module rec V : sig

      type 'k v =
        | Empty | Unv
        | Rel of S.event_rel
        | Set of S.event_set
        | Clo of 'k closure
        | Prim of string * int * ('k v -> 'k v)
        | Proc of 'k procedure
        | Tag of string * string     (* type  X name *)
        | ValSet of typ * 'k ValSet.t   (* elt type X set *)
        | Tuple of 'k v list
        | Kont of ('k v -> 'k -> 'k) * 'k

      and 'k env =
          { vals  : 'k v Lazy.t StringMap.t;
            enums : string list StringMap.t;
            tags  : string StringMap.t; }
      and 'k closure =
          { clo_args : AST.pat ;
            mutable clo_env : 'k env ;
            clo_body : AST.exp;
            clo_name : string * int; } (* unique id (hack) *)

      and 'k procedure = {
          proc_args : AST.pat ;
          proc_env : 'k env;
          proc_body : AST.ins list; }

      val type_val : 'k v -> typ

    end = struct


      type 'k v =
        | Empty | Unv
        | Rel of S.event_rel
        | Set of S.event_set
        | Clo of 'k closure
        | Prim of string * int * ('k v -> 'k v)
        | Proc of 'k procedure
        | Tag of string * string     (* type  X name *)
        | ValSet of typ * 'k ValSet.t   (* elt type X set *)
        | Tuple of 'k v list
        | Kont of ('k v -> 'k -> 'k) * 'k

      and 'k env =
          { vals  : 'k v Lazy.t StringMap.t;
            enums : string list StringMap.t;
            tags  : string StringMap.t; }
      and 'k closure =
          { clo_args : AST.pat ;
            mutable clo_env : 'k env ;
            clo_body : AST.exp;
            clo_name : string * int; } (* unique id (hack) *)

      and 'k procedure = {
          proc_args : AST.pat ;
          proc_env : 'k env;
          proc_body : AST.ins list; }

      let rec type_val = function
        | V.Empty -> TEmpty
        | Unv -> assert false (* Discarded before *)
        | Rel _ -> TRel
        | Set _ -> TEvents
        | Clo _|Prim _ -> TClo
        | Proc _ -> TProc
        | Tag (t,_) -> TTag t
        | ValSet (t,_) -> TSet t
        | Tuple vs -> TTuple (List.map type_val vs)
        | Kont _ -> TKont

   end
    and ValOrder : PolySet.OrderedType with type 'k t = 'k V.v = struct
      (* Note: cannot use Full in sets.. *)
      type 'k t = 'k V.v
      open V

      let error fmt = ksprintf (fun msg -> raise (CompError msg)) fmt


      let rec compare v1 v2 = match v1,v2 with
      | V.Empty,V.Empty -> 0
(* Expand all legitimate empty's *)
      | V.Empty,ValSet (_,s) -> ValSet.compare ValSet.empty s
      | ValSet (_,s),V.Empty -> ValSet.compare s ValSet.empty
      | V.Empty,Rel r -> E.EventRel.compare E.EventRel.empty r
      | Rel r,V.Empty -> E.EventRel.compare r E.EventRel.empty
      | V.Empty,Set s -> E.EventSet.compare E.EventSet.empty s
      | Set s,V.Empty -> E.EventSet.compare s E.EventSet.empty
(* Legitimate cmp *)
      | Tag (_,s1), Tag (_,s2) -> String.compare s1 s2
      | ValSet (_,s1),ValSet (_,s2) -> ValSet.compare s1 s2
      | Rel r1,Rel r2 -> E.EventRel.compare r1 r2
      | Set s1,Set s2 -> E.EventSet.compare s1 s2
      | (Clo {clo_name = (_,i1);_},Clo {clo_name=(_,i2);_})
      | (Prim (_,i1,_),Prim (_,i2,_)) -> Pervasives.compare i1 i2
      | Clo _,Prim _ -> 1
      | Prim _,Clo _ -> -1
      | Tuple vs,Tuple ws ->  compares vs ws
(* Errors *)
      | (Unv,_)|(_,Unv) -> error "Universe in compare"
      | _,_ ->
          let t1 = V.type_val v1
          and t2 = V.type_val v2 in
          if type_equal t1 t2 then
            error "Sets of %s are illegal" (pp_typ t1)
          else
            error
              "Heterogeneous set elements: types %s and %s "
              (pp_typ t1) (pp_typ t2)

      and compares vs ws = match vs,ws with
      | [],[] -> 0
      | [],_::_ -> -1
      | _::_,[] -> 1
      | v::vs,w::ws ->
          begin match compare v w with
          | 0 -> compares vs ws
          | r -> r
          end

    end and ValSet : (PolySet.S with type 'k elt = 'k V.v) =
        PolySet.Make(ValOrder)

    type 'k fix = CheckFailed of 'k V.env | CheckOk of 'k V.env

    let error silent loc fmt =
      ksprintf
        (fun msg ->
          if O.debug || not silent then eprintf "%a: %s\n" TxtLoc.pp loc msg ;
          raise Misc.Exit) (* Silent failure *)
        fmt

    let warn loc fmt =      
      ksprintf
        (fun msg ->
          Warn.warn_always "%a: %s" TxtLoc.pp loc msg)
        fmt

    open V

(* pretty *)
    let pp_type_val v = pp_typ (type_val v)

    let rec pp_val = function
      | Unv -> "<universe>"
      | V.Empty -> "{}"
      | Tag (_,s) -> sprintf "'%s" s
      | ValSet (_,s) ->
          sprintf "{%s}" (ValSet.pp_str "," pp_val s)
      | Clo {clo_name=(n,x);_} ->
          sprintf "%s_%i" n x
      | V.Tuple vs ->
          sprintf "(%s)" (String.concat "," (List.map pp_val vs))
      | v -> sprintf "<%s>" (pp_type_val v)

    let rec debug_val chan = function
      | ValSet (_,s) ->
          output_char chan '{' ;
          ValSet.pp chan "," debug_val s ;
          output_char chan '}'
      | Set es ->  debug_set chan es
      | Rel r  -> debug_rel chan r
      | v -> fprintf chan "%s" (pp_val v)

(* lift a tag to a singleton set *)
    let tag2set v = match v with
    | V.Tag (t,_) -> ValSet (TTag t,ValSet.singleton v)
    | _ -> v

(* extract lists from tuples *)
    let pat_as_vars = function
      | Pvar x -> [x]
      | Ptuple xs -> xs

    let v_as_vs = function
      | V.Tuple vs -> vs
      | v -> [v]

    let pat2empty = function
      | Pvar _ -> V.Empty
      | Ptuple xs -> V.Tuple (List.map (fun _ -> V.Empty) xs)

      let bdvars (_,pat,_) = match pat with
      | Pvar x -> StringSet.singleton x
      | Ptuple xs -> StringSet.of_list xs


(* Add values to env *)
    let add_val k v env =
      { env with vals = StringMap.add k v env.vals; }


    let add_pat_val silent loc pat v env = match pat with
    | Pvar k -> add_val k v env
    | Ptuple ks ->
        let rec add_rec extract env = function
          | [] -> env
          | k::ks ->
              let vk =
                lazy
                  begin match extract (Lazy.force v) with
                  | v::_ -> v
                  | [] -> error silent loc "%s" "binding mismatch"
                  end in
              let env = add_val k vk env
              and extract v = match extract v with
              | _::vs -> vs
              | [] -> error silent loc "%s" "binding mismatch" in
              add_rec extract env ks in
        add_rec v_as_vs env ks

    let env_empty =
      {vals=StringMap.empty;
       enums=StringMap.empty;
       tags=StringMap.empty; }

(* Hackish: check absence of continuation on env + change type param *)
    let tr_v = fun (type a) (type b) silent loc (v:a V.v) -> match v with
      | Kont _ ->
          error silent loc "kont value used during internal evaluation"
      | v -> (Obj.magic v:b V.v)

    let purge_env silent loc t =
      let venv =
        StringMap.fold
          (fun x v k ->
            if true then
              let nv = lazy begin tr_v silent loc (Lazy.force v) end in
              StringMap.add x nv k
            else k)
          t.vals StringMap.empty in
      { t with vals = venv;}


(* Initial env, a restriction of env *)

    type init_env =
        E.EventSet.t Lazy.t Misc.Simple.bds *
          E.EventRel.t Lazy.t Misc.Simple.bds 

    let init_env_empty = [],[]

    let add_rels (sets,rels) bds = (sets,bds@rels)

    and add_sets (sets,rels) bds = (bds@sets,rels)

(* Go on *)
    let add_vals mk =
      List.fold_right (fun (k,v) -> StringMap.add k (mk v))

    let env_from_ienv (sets,rels) =
      let vals =
        add_vals (fun v -> lazy (Set (Lazy.force v))) sets StringMap.empty in
      let vals =
        add_vals (fun v -> lazy (Rel (Lazy.force v))) rels vals in
      { env_empty with vals; }

(* Primmitive added internally to actual env *)
    let add_prims env bds =
      let vals = env.vals in
      let vals =
        List.fold_left
          (fun vals (k,f) ->
            StringMap.add k (lazy (Prim (k,next_id (),f)))
              vals)
          vals bds in
      { env with vals; }

    type loc = { stack : (TxtLoc.t * string option) list ; txt : string ; }

    type 'k st = {
        env : 'k V.env ;
        show : S.event_rel StringMap.t Lazy.t ;
        skipped : StringSet.t ;
        silent : bool ; flags : Flag.Set.t ;
        ks : ks ;
        bell_info : BellModel.info ;
        loc : loc ;
      }

(* Interpretation result *)

      type st_out = {
       out_show : S.event_rel Misc.Simple.bds Lazy.t ;
       out_skipped : StringSet.t ;
       out_flags : Flag.Set.t ;
       out_bell_info :  BellModel.info ;       
      }

(* Remove transitive edges, except if instructed not to *)
    let rt_loc lbl =
      if
        O.verbose <= 1 &&
        not (StringSet.mem lbl O.symetric) &&
        not (StringSet.mem lbl O.showraw)
      then E.EventRel.remove_transitive_edges else (fun x -> x)

    let show_to_vbpp st =
      StringMap.fold (fun tag v k -> (tag,v)::k)   (Lazy.force st.show) []

    let st2out st =
      {out_show = lazy (show_to_vbpp st) ;
       out_skipped = st.skipped ;
       out_flags = st.flags ;
       out_bell_info = st.bell_info ; }


    let push_loc st loc =
      let loc = { st.loc with stack = loc :: st.loc.stack; } in
      { st with loc; }
    let pop_loc st = match st.loc.stack with
    | [] -> assert false
    | _::stack ->
        let loc = { st.loc with stack; } in
        { st with loc; }

    let show_loc (loc,name) =
      eprintf "%a: calling procedure%s\n" TxtLoc.pp loc
        (match name with
        | None -> ""
        | Some n -> " as " ^ n)

    let show_call_stack st = List.iter show_loc st.stack

    let protect_call st f x =
      try f x
      with Misc.Exit ->
        List.iter
          (fun loc -> if O.debug || not st.silent then show_loc loc)
          st.loc.stack ;
        raise Misc.Exit

(* Type of eval env *)
    module EV = struct
      type 'k env =
          { env : 'k V.env ; silent : bool; ks : ks; }
    end
    let from_st st = { EV.env=st.env; silent=st.silent; ks=st.ks; }

    let set_op env loc t op s1 s2 =
      try V.ValSet (t,op s1 s2)
      with CompError msg -> error env.EV.silent loc "%s" msg

    let tags_universe {enums=env} t =
      let tags =
        try StringMap.find t env
        with Not_found -> assert false in
      let tags = ValSet.of_list (List.map (fun s -> V.Tag (t,s)) tags) in
      tags

    let find_env {vals=env} k =
      Lazy.force begin
        try StringMap.find k env
        with
        | Not_found -> Warn.user_error "unbound var: %s" k
      end

    let find_env_loc loc env k =
      try  find_env env.EV.env k
      with Misc.UserError msg -> error env.EV.silent loc "%s" msg

(* find without forcing lazy's *)
    let just_find_env fail loc env k =
      try StringMap.find k env.EV.env.vals
      with Not_found ->
        if fail then error env.EV.silent loc "unbound var: %s" k
        else raise Not_found

    let as_rel ks = function
      | Rel r -> r
      | Empty -> E.EventRel.empty
      | Unv -> Lazy.force ks.unv
      | v ->
          eprintf "not a relation: '%s'\n" (pp_val v) ;
          assert false

    let as_set ks = function
      | Set s -> s
      | Empty -> E.EventSet.empty
      | Unv -> ks.evts
      | _ -> assert false

    let as_valset = function
      | ValSet (_,v) -> v
      | _ -> assert false

    let as_tag = function
      | V.Tag (_,tag) -> tag
      | _ -> assert false

    let as_tags tags =
      let ss = ValSet.fold (fun v k -> as_tag v::k) tags [] in
      StringSet.of_list ss

    exception Stabilised of typ

    let stabilised ks env =
      let rec stabilised vs ws = match vs,ws with
      | [],[] -> true
      | v::vs,w::ws -> begin match v,w with
        | (_,V.Empty)|(Unv,_) -> stabilised vs ws
(* Relation *)
        | (V.Empty,Rel w) -> E.EventRel.is_empty w && stabilised vs ws
        | (Rel v,Unv) ->
            E.EventRel.subset (Lazy.force ks.unv) v && stabilised vs ws
        | Rel v,Rel w ->
            E.EventRel.subset w v && stabilised vs ws
(* Event Set *)
        | (V.Empty,Set w) -> E.EventSet.is_empty w && stabilised vs ws
        | (Set v,Unv) ->
            E.EventSet.subset ks.evts v && stabilised vs ws
        | Set v,Set w ->
            E.EventSet.subset w v && stabilised vs ws
(* Value Set *)
        | (V.Empty,ValSet (_,w)) -> ValSet.is_empty w && stabilised vs ws
        | (ValSet (TTag t,v),Unv) ->
            ValSet.subset (tags_universe env t) v && stabilised vs ws
        | ValSet (_,v),ValSet (_,w) ->
            ValSet.subset w v && stabilised vs ws
        | _,_ ->
            raise (Stabilised (type_val w))

      end
      | _,_ -> assert false in
      stabilised


(* Syntactic function *)
    let is_fun = function
      | Fun _ -> true
      | _ -> false


(* Get an expression location *)
    let get_loc = function
      | Konst (loc,_)
      | AST.Tag (loc,_)
      | Var (loc,_)
      | ExplicitSet (loc,_)
      | Op1 (loc,_,_)
      | Op (loc,_,_)
      | Bind (loc,_,_)
      | BindRec (loc,_,_)
      | App (loc,_,_)
      | Fun (loc,_,_,_,_)
      | Match (loc,_,_,_)
      | MatchSet (loc,_,_,_)
      | Try (loc,_,_)
      | If (loc,_,_,_)
      | Yield (loc,_,_)
        -> loc


    let empty_rel = Rel E.EventRel.empty
        
    let error_typ silent loc t0 t1  =
      error silent loc"type %s expected, %s found" (pp_typ t0) (pp_typ t1)

    let error_rel silent loc v = error_typ silent loc TRel (type_val v)


(********************************)
(* Helpers for n-ary operations *)
(********************************)

    let type_list silent = function
      | [] -> assert false
      | (_,v)::vs ->
          let rec type_rec t0 = function
            | [] -> t0,[]
            | (loc,v)::vs ->
                let t1 = type_val v in
                match eq_type t0 t1 with
                | Some t0 ->
                    let t0,vs = type_rec t0 vs in
                    t0,v::vs
                | None ->
                    error silent loc
                      "type %s expected, %s found" (pp_typ t0) (pp_typ t1) in
          let t0,vs = type_rec (type_val v) vs in
          t0,v::vs


(* Check explicit set arguments *)
    let set_args silent =
      let rec s_rec = function
        | [] -> []
        | (loc,Unv)::_ ->
            error silent loc "universe in explicit set"
        | x::xs -> x::s_rec xs in
      s_rec

(* Union is polymorphic *)
    let union_args =
      let rec u_rec = function
        | [] -> []
        | (_,V.Empty)::xs -> u_rec xs
        | (_,Unv)::_ -> raise Exit
        | (loc,v)::xs ->
            (loc,tag2set v)::u_rec xs in
      u_rec

(* Sequence applies to relations *)
    let seq_args silent ks =
      let rec seq_rec = function
        | [] -> []
        | (_,V.Empty)::_ -> raise Exit
        | (_,V.Unv)::xs -> Lazy.force ks.unv::seq_rec xs
        | (_,Rel r)::xs -> r::seq_rec xs
        | (loc,v)::_ -> error_rel silent loc v in
      seq_rec

(* Definition of primitives *)
    let arg_mismatch () = raise (PrimError "argument mismatch")

    let partition arg = match arg with
    | Set evts ->
        let r = U.partition_events evts in
        let vs = List.map (fun es -> Set es) r in
        ValSet (TEvents,ValSet.of_list vs)
    | _ -> arg_mismatch ()

    and classes arg =  match arg with
    | Rel r ->
        let r = E.EventRel.classes r in
        let vs = List.map (fun es -> Set es) r in
        ValSet (TEvents,ValSet.of_list vs)
    | _ -> arg_mismatch ()

    and linearisations arg = match arg with
    | V.Tuple [Set es;Rel r;] ->
        if O.debug && O.verbose > 1 then begin
          eprintf "Linearisations:\n" ;
          eprintf "  %a\n" debug_set es ;
          eprintf "  {%a}\n"
            debug_rel
            (E.EventRel.filter
               (fun (e1,e2) ->
                 E.EventSet.mem e1 es && E.EventSet.mem e2 es)
               r)
        end ;
        let rs =
          apply_orders es r
            (fun o ->
              let o =
                E.EventRel.filter
                  (fun (e1,e2) ->
                    E.EventSet.mem e1 es && E.EventSet.mem e2 es)
                  o in
              if O.debug then begin
                eprintf
                  "Linearisation failed {%a}\n%!" debug_rel o ;
                ValSet.singleton (V.Rel o)
              end else
                ValSet.empty)
            (fun o os ->
              if O.debug && O.verbose > 1 then
                eprintf "  -> {%a}\n%!" debug_rel o ;
              ValSet.add (Rel o) os)
            ValSet.empty in
        ValSet (TRel,rs)
    | _ -> arg_mismatch ()

    and tag2scope env arg = match arg with
    | V.Tag (_,tag) ->
        begin try
          let v = Lazy.force (StringMap.find tag env.vals) in
          match v with
          | V.Empty|V.Unv|V.Rel _ ->  v
          | _ ->
              raise
                (PrimError
                   (sprintf
                      "value %s is not a relation, found %s"
                      tag  (pp_type_val v)))
                
        with Not_found ->
          raise
            (PrimError (sprintf "cannot find scope instance %s" tag))
        end
    | _ -> arg_mismatch ()

    and tag2events env arg = match arg with
    | V.Tag (_,tag) ->
        let x = BellName.tag2events_var tag in
        begin try
          let v = Lazy.force (StringMap.find x env.vals) in
          match v with
          | V.Empty|V.Unv|V.Set _ ->  v
          | _ ->
              raise
                (PrimError
                   (sprintf
                      "value %s is not a set of events, found %s"
                      x  (pp_type_val v)))
                
        with Not_found ->
          raise
            (PrimError (sprintf "cannot find event set %s" x))
        end
    | _ -> arg_mismatch ()

    and domain arg = match arg with
    | V.Empty ->  V.Empty
    | V.Unv -> V.Unv
    | V.Rel r ->  V.Set (E.EventRel.domain r)
    | _ -> arg_mismatch ()

    and range arg = match arg with
    | V.Empty ->  V.Empty
    | V.Unv -> V.Unv
    | V.Rel r ->  V.Set (E.EventRel.codomain r)
    | _ -> arg_mismatch ()

    and fail arg =
      let pp = pp_val arg in
      let msg = sprintf "fail on %s" pp in
      raise (PrimError msg)

    let add_primitives m =
      add_prims m
        [
         "partition",partition;
         "classes",classes;
         "linearisations",linearisations;
         "tag2scope",tag2scope m;
         "tag2events",tag2events m;
         "domain",domain;
         "range",range;
         "fail",fail;
       ]

        
(***************)
(* Interpreter *)
(***************)

(* For all success call kont, accumulating results *)
    let interpret test =

      let rec eval_loc env e = get_loc e,eval env e

      and eval env = function
        | Konst (_,AST.Empty SET) -> V.Empty (* Polymorphic empty *)
        | Konst (_,AST.Empty RLN) -> empty_rel
        | Konst (_,Universe _) -> Unv
        | AST.Tag (loc,s) ->
            begin try
              V.Tag (StringMap.find s env.EV.env.tags,s)
            with Not_found ->
              error env.EV.silent loc "tag '%s is undefined" s
            end
        | Var (loc,k) ->
            find_env_loc loc env k
        | Fun (loc,xs,body,name,fvs) ->
            Clo (eval_fun false env loc xs body name fvs)
(* Unary operators *)
        | Op1 (_,Plus,e) ->
            begin match eval env e with
            | V.Empty -> V.Empty
            | Unv -> Unv
            | Rel r -> Rel (E.EventRel.transitive_closure r)
            | v -> error_rel env.EV.silent (get_loc e) v
            end
        | Op1 (_,Star,e) ->
            begin match eval env e with
            | V.Empty -> Rel (Lazy.force env.EV.ks.id)
            | Unv -> Unv
            | Rel r ->
                Rel
                  (E.EventRel.union
                     (E.EventRel.transitive_closure r) 
                     (Lazy.force env.EV.ks.id))
            | v -> error_rel env.EV.silent (get_loc e) v
            end
        | Op1 (_,Opt,e) ->
            begin match eval env e with
            | V.Empty -> Rel (Lazy.force env.EV.ks.id)
            | Unv -> Unv
            | Rel r ->
                Rel (E.EventRel.union r (Lazy.force env.EV.ks.id))
            | v -> error_rel env.EV.silent (get_loc e) v
            end
        | Op1 (_,Comp,e) -> (* Back to polymorphism *)
            begin match eval env e with
            | V.Empty -> Unv
            | Unv -> V.Empty
            | Set s ->
                Set (E.EventSet.diff env.EV.ks.evts s)
            | Rel r ->
                Rel (E.EventRel.diff (Lazy.force env.EV.ks.unv) r)
            | ValSet (TTag ts as t,s) ->
                ValSet (t,ValSet.diff (tags_universe env.EV.env ts) s)
            | v ->
                error env.EV.silent (get_loc e)
                  "set or relation expected, %s found"
                  (pp_typ (type_val v))
            end
        | Op1 (_,Inv,e) ->
            begin match eval env e with
            | V.Empty -> V.Empty
            | Unv -> Unv
            | Rel r -> Rel (E.EventRel.inverse r)
            | v -> error_rel env.EV.silent (get_loc e) v
            end
(* One xplicit N-ary operator *)
        | ExplicitSet (loc,es) ->
            let vs = List.map (eval_loc env) es in
            let vs = set_args env.EV.silent vs in
            begin match vs with
            | [] -> V.Empty
            | _ ->
                let t,vs = type_list env.EV.silent vs in
                try ValSet (t,ValSet.of_list vs)
                with CompError msg ->
                  error env.EV.silent loc "%s" msg
            end
(* Tuple is an actual N-ary operator *)
        | Op (_loc,AST.Tuple,es) ->
            V.Tuple (List.map (eval env) es)
(* N-ary operators, those associative binary operators are optimized *)
        | Op (loc,Union,es) ->
            let vs = List.map (eval_loc env) es in
            begin try
              let vs = union_args vs in
              match vs with
              | [] -> V.Empty
              | _ ->
                  let t,vs = type_list env.EV.silent vs in
                  match t with
                  | TRel ->
                      Rel (E.EventRel.unions (List.map (as_rel env.EV.ks) vs))
                  | TEvents ->
                      Set (E.EventSet.unions  (List.map (as_set env.EV.ks) vs))
                  | TSet telt ->
                      ValSet (telt,ValSet.unions (List.map as_valset vs))
                  | ty ->
                      error env.EV.silent loc
                        "cannot perform union on type '%s'" (pp_typ ty)
            with Exit -> Unv end
        | Op (_,Seq,es) ->
            let vs = List.map (eval_loc env) es in
            begin try
              let vs = seq_args env.EV.silent env.EV.ks vs in
              let r =
                List.fold_right
                  E.EventRel.sequence
                  vs (Lazy.force env.EV.ks.id) in
              Rel r
            with Exit -> empty_rel
            end
(* Binary operators *)
        | Op (_loc1,Inter,[e1;Op (_loc2,Cartesian,[e2;e3])])
        | Op (_loc1,Inter,[Op (_loc2,Cartesian,[e2;e3]);e1]) ->
            let r = eval_rel env e1
            and f1 = eval_set_mem env e2
            and f2 = eval_set_mem env e3 in
            let r =
              E.EventRel.filter
                (fun (e1,e2) -> f1 e1 && f2 e2)
                r in
            Rel r              
        | Op (loc,Inter,[e1;e2;]) -> (* Binary notation kept in parser *)
            let loc1,v1 = eval_loc env e1
            and loc2,v2 = eval_loc env e2 in
            begin match tag2set v1,tag2set v2 with
            | (V.Tag _,_)|(_,V.Tag _) -> assert false
            | Rel r1,Rel r2 -> Rel (E.EventRel.inter r1 r2)
            | Set s1,Set s2 -> Set (E.EventSet.inter s1 s2)
            | ValSet (t,s1),ValSet (_,s2) ->
                set_op env loc t ValSet.inter s1 s2
            | (Unv,r)|(r,Unv) -> r
            | (V.Empty,_)|(_,V.Empty) -> V.Empty
            | (Clo _|Prim _|Proc _|V.Tuple _|Kont _),_ ->
                error env.EV.silent loc1
                  "intersection on %s" (pp_typ (type_val v1))
            | _,(Clo _|Prim _|Proc _|V.Tuple _|Kont _) ->
                error env.EV.silent loc2
                  "intersection on %s" (pp_typ (type_val v2))
            | (Rel _,Set _)
            | (Set _,Rel _)
            | (Rel _,ValSet _)
            | (ValSet _,Rel _) ->
                error env.EV.silent
                  loc "mixing sets and relations in intersection"
            | (ValSet _,Set _)
            | (Set _,ValSet _) ->
                error env.EV.silent
                  loc "mixing event sets and sets in intersection"
            end
        | Op (loc,Diff,[e1;e2;]) ->
            let loc1,v1 = eval_loc env e1
            and loc2,v2 = eval_loc env e2 in
            begin match tag2set v1,tag2set v2 with
            | (V.Tag _,_)|(_,V.Tag _) -> assert false
            | Rel r1,Rel r2 -> Rel (E.EventRel.diff r1 r2)
            | Set s1,Set s2 -> Set (E.EventSet.diff s1 s2)
            | ValSet (t,s1),ValSet (_,s2) ->
                set_op env loc t ValSet.diff s1 s2
            | Unv,Rel r -> Rel (E.EventRel.diff (Lazy.force env.EV.ks.unv) r)
            | Unv,Set s -> Set (E.EventSet.diff env.EV.ks.evts s)
            | Unv,ValSet (TTag ts as t,s) ->
                ValSet (t,ValSet.diff (tags_universe env.EV.env ts) s)
            | Unv,ValSet (t,_) ->
                error env.EV.silent
                  loc1 "cannot build universe for element type %s"
                  (pp_typ t)
            | Unv,V.Empty -> Unv
            | (Rel _|Set _|V.Empty|Unv|ValSet _),Unv
            | V.Empty,(Rel _|Set _|V.Empty|ValSet _) -> V.Empty
            | (Rel _|Set _|ValSet _),V.Empty -> v1
            | (Clo _|Proc _|Prim _|V.Tuple _|Kont _),_ ->
                error env.EV.silent loc1
                  "difference on %s" (pp_typ (type_val v1))
            | _,(Clo _|Proc _|Prim _|V.Tuple _|Kont _) ->
                error env.EV.silent loc2
                  "difference on %s" (pp_typ (type_val v2))
            | ((Set _|ValSet _),Rel _)|(Rel _,(Set _|ValSet _)) ->
                error env.EV.silent
                  loc "mixing set and relation in difference"
            | (Set _,ValSet _)|(ValSet _,Set _) ->
                error env.EV.silent
                  loc "mixing event set and set in difference"
            end
        | Op (_,Cartesian,[e1;e2;]) ->
            let s1 = eval_set env e1
            and s2 = eval_set env e2 in
            Rel (E.EventRel.cartesian s1 s2)
        | Op (loc,Add,[e1;e2;]) ->
            let v1 = eval env e1
            and v2 = eval env e2 in
            begin match v1,v2 with
            | V.Unv,_ -> error env.EV.silent loc "universe in set ++"
            | _,V.Unv -> V.Unv
            | _,V.Empty -> V.ValSet (type_val v1,ValSet.singleton v1)
            | V.Empty,V.ValSet (TSet e2 as t2,s2) ->
                let v1 = ValSet (e2,ValSet.empty) in
                set_op env loc t2 ValSet.add v1 s2
            | _,V.ValSet (_,s2) ->
                set_op env loc (type_val v1) ValSet.add v1 s2
            | _,(Rel _|Set _|Clo _|Prim _|Proc _|V.Tag (_, _)|V.Tuple _|Kont _) ->
                error env.EV.silent (get_loc e2)
                  "this expression of type '%s' should be a set"
                  (pp_typ (type_val v2))
            end
        | Op (_,(Diff|Inter|Cartesian|Add),_) -> assert false (* By parsing *)
(* Application/bindings *)
        | App (loc,f,e) ->
            eval_app loc env (eval env f) (eval env e)
        | Bind (_,bds,e) ->
            let m = eval_bds env bds in
            eval { env with EV.env = m;} e
        | BindRec (loc,bds,e) ->
            let m =
              match env_rec (fun _ -> true)
                  env loc (fun pp -> pp) bds
              with
              | CheckOk env -> env
              | CheckFailed _ -> assert false (* No check in expr binding *) in
            eval { env with EV.env=m;} e
        | Match (loc,e,cls,d) ->
            let v = eval env e in
            begin match v with
            | V.Tag (_,s) ->
                let rec match_rec = function
                  | [] ->
                      begin match d with
                      | Some e ->  eval env e
                      | None ->
                          error env.EV.silent
                            loc "pattern matching failed on value '%s'" s
                      end
                  | (ps,es)::cls ->
                      if s = ps then eval env es
                      else match_rec cls in
                match_rec cls
            | V.Empty ->
                error env.EV.silent (get_loc e) "matching on empty"
            | V.Unv ->
                error env.EV.silent (get_loc e) "matching on universe"
            | _ ->
                error env.EV.silent (get_loc e)
                  "matching on non-tag value of type '%s'"
                  (pp_typ (type_val v))
            end
        | MatchSet (loc,e,ife,(x,xs,ex)) ->
            let v = eval env e in
            begin match v with
            | V.Empty -> eval env ife
            | V.Unv ->
                error env.EV.silent loc
                  "%s" "Cannot set-match on universe"
            | V.ValSet (t,s) ->
                if ValSet.is_empty s then
                  eval env ife
                else
                  let elt =
                    lazy begin
                      try ValSet.choose s
                      with Not_found -> assert false
                    end in
                  let s =
                    lazy begin
                      try ValSet (t,ValSet.remove (Lazy.force elt) s)
                      with  CompError msg ->
                        error env.EV.silent (get_loc e) "%s" msg
                    end in
                  let m = env.EV.env in
                  let m = add_val x elt m in
                  let m = add_val xs s m in
                  eval { env with EV.env = m; }ex
            | _ ->
                error env.EV.silent
                  (get_loc e) "set-matching on non-set value of type '%s'"
                  (pp_typ (type_val v))
            end
        | Try (loc,e1,e2) ->
            begin
              try eval { env with EV.silent = true; } e1
              with Misc.Exit ->
                if O.debug then warn loc "caught failure" ;
                eval env e2
            end
        | If (_loc,cond,ifso,ifnot) ->
            if eval_cond env cond then eval env ifso
            else eval env ifnot
        | Yield (_loc,res,a) ->
            let v = eval env a
            and vres = eval env res in
            begin match vres with
            | Kont (kont,res) -> Kont (kont,kont v res)
            | _ ->
                error env.EV.silent (get_loc res)
                  "continuation expected, %s found" (pp_val vres)
            end

      and eval_cond env c = match c with
      | Eq (e1,e2) ->
          let v1 = eval env e1
          and v2 = eval env e2 in
          ValOrder.compare v1 v2 = 0
              
      and eval_app loc env vf va = match vf with
      | Clo f ->
          let env =
            { env with
              EV.env=add_args loc f.clo_args va env f.clo_env;} in
          if O.debug then begin try
            eval env f.clo_body
          with
          |  Misc.Exit ->
              error env.EV.silent loc "Calling"
          | e ->
              error env.EV.silent loc "Calling (%s)" (Printexc.to_string e)
          end else
            eval env f.clo_body
      | Prim (name,_,f) ->
          begin try f va with
          | PrimError msg ->
              error env.EV.silent loc "primitive %s: %s" name msg
          | Misc.Exit ->
              error env.EV.silent loc "Calling primitive %s" name
          end
      | _ -> error env.EV.silent loc "closure or primitive expected"
            
      and eval_fun is_rec env loc pat body name fvs =
        if O.debug && O.verbose > 1 then begin
          let sz =
            StringMap.fold
              (fun _ _ k -> k+1) env.EV.env.vals 0 in
          let fs = StringSet.pp_str "," (fun x -> x) fvs in
          warn loc "Closure %s, env=%i, free={%s}" name sz fs
        end ;
        let vals =
          StringSet.fold
            (fun x k ->
              try
                let v = just_find_env (not is_rec) loc env x in
                StringMap.add x v k
              with Not_found -> k)
            fvs StringMap.empty in
        let env = { env.EV.env with vals; } in
        {clo_args=pat; clo_env=env; clo_body=body; clo_name=(name,next_id ()); }

      and add_args loc pat v env_es env_clo =
        let xs = pat_as_vars pat
        and vs = v_as_vs v in
        let bds =
          try
            List.combine xs vs
          with _ -> error env_es.EV.silent loc "argument_mismatch" in
        let env_call =
          List.fold_right
            (fun (x,v) env -> add_val x (lazy v) env)
            bds env_clo in
        env_call

      and eval_rel env e =  match eval env e with
      | Rel v -> v
      | V.Empty -> E.EventRel.empty
      | Unv -> Lazy.force env.EV.ks.unv
      | _ -> error env.EV.silent (get_loc e) "relation expected"

      and eval_set env e = match eval env e with
      | Set v -> v
      | V.Empty -> E.EventSet.empty
      | Unv -> env.EV.ks.evts
      | _ -> error env.EV.silent (get_loc e) "set expected"

      and eval_set_mem env e = match eval env e with
      | Set s -> fun e -> E.EventSet.mem e s
      | V.Empty -> fun _ -> false
      | Unv -> fun _ -> true
      |  _ -> error env.EV.silent (get_loc e) "set expected"

      and eval_proc loc env x = match find_env_loc loc env x with
      | Proc p -> p
      | _ ->
          Warn.user_error "procedure expected"

(* For let *)
      and eval_bds env_bd  =
        let rec do_rec bds = match bds with
        | [] -> env_bd.EV.env
        | (loc,p,e)::bds ->
            (*
              begin match v with
              | Rel r -> printf "Defining relation %s = {%a}.\n" k debug_rel r
              | Set s -> printf "Defining set %s = %a.\n" k debug_set s
              | Clo _ -> printf "Defining function %s.\n" k
              end;
             *)
            add_pat_val env_bd.EV.silent loc
              p (lazy (eval env_bd e)) (do_rec bds) in
        do_rec

(* For let rec *)

      and env_rec check env loc pp bds =
        let fs,nfs =  List.partition  (fun (_,_,e) -> is_fun e) bds in
        let fs =
          List.map
            (fun (loc,p,e) -> match p with
            | Pvar x -> x,e
            | Ptuple _ ->
                error env.EV.silent loc "%s" "binding mismatch")
            fs in
        match nfs with
        | [] -> CheckOk (env_rec_funs env loc fs)
        | _  -> env_rec_vals check env loc pp fs nfs


(* Recursive functions *)
      and env_rec_funs env_bd _loc bds =
        let env = env_bd.EV.env in
        let clos =
          List.map
            (function
              | f,Fun (loc,xs,body,name,fvs) ->
                  f,eval_fun true env_bd loc xs body name fvs,fvs
              | _ -> assert false)
            bds in
        let add_funs pred env =
          List.fold_left
            (fun env (f,clo,_) ->
              if pred f then add_val f (lazy (Clo clo)) env
              else env)
            env clos in
        List.iter
          (fun (_,clo,fvs) ->
            clo.clo_env <-
              add_funs (fun x -> StringSet.mem x fvs) clo.clo_env)
          clos ;
        add_funs (fun _ -> true) env


(* Compute fixpoint of relations *)
      and env_rec_vals check env_bd loc pp funs bds =

        (* Pretty print (relation) current values *)
        let vb_pp vs =
          List.fold_left2
            (fun k (_loc,pat,_) v ->
              let pp_id x v k =
                try
                  let v = match v with
                  | V.Empty -> E.EventRel.empty
                  | Unv -> Lazy.force env_bd.EV.ks.unv
                  | Rel r -> r
                  | _ -> raise Exit in
                  (x, rt_loc x v)::k
                with Exit -> k in
              let rec pp_ids xs vs k = match xs,vs with
              | ([],_)|(_,[]) -> k (* do not fail for pretty print *)
              | x::xs,v::vs ->
                  pp_id x v (pp_ids xs vs k) in
              match pat with
              | Pvar x -> pp_id x v k
              | Ptuple xs -> pp_ids xs (v_as_vs v) k)
            [] bds vs in

(* Fixpoint iteration *)
        let rec fix k env vs =
          if O.debug && O.verbose > 1 then begin
            let vb_pp = pp (vb_pp vs) in
            U.pp_failure test env_bd.EV.ks.conc (sprintf "Fix %i" k) vb_pp
          end ;
          let env,ws = fix_step env_bd env bds in
          let env = env_rec_funs { env_bd with EV.env=env;} loc funs in
          let check_ok = check { env_bd with EV.env=env; } in
          if not check_ok then begin
            if O.debug then warn loc "Fix point interrupted" ;
            CheckFailed env
          end else
            let over =
              begin try stabilised env_bd.EV.ks env vs ws
              with Stabilised t ->
                error env_bd.EV.silent loc "illegal recursion on type '%s'"
                  (pp_typ t)
              end in
            if over then CheckOk env
            else fix (k+1) env ws in

        let env0 =
          List.fold_left
            (fun env (_,pat,_) -> match pat with
            | Pvar k -> add_val k (lazy V.Empty) env
            | Ptuple ks ->
                List.fold_left
                  (fun env k -> add_val k (lazy V.Empty) env)
                  env ks)
            env_bd.EV.env bds in
        let env0 = env_rec_funs { env_bd with EV.env=env0;} loc funs in
        let env =
          if O.bell then CheckOk env0 (* Do not compute fixpoint in bell *)
          else fix 0 env0 (List.map (fun (_,pat,_) -> pat2empty pat) bds) in
        if O.debug then warn loc "Fix point over" ;
        env

      and fix_step env_bd env bds = match bds with
      | [] -> env,[]
      | (loc,k,e)::bds ->
          let v = eval {env_bd with EV.env=env;} e in
          let env = add_pat_val env_bd.EV.silent loc k (lazy v) env in
          let env,vs = fix_step env_bd env bds in
          env,(v::vs) in

(* Showing bound variables, (-doshow option) *)

      let find_show_rel ks env x =

        let as_rel v = match v with
        | Rel r -> r
        | V.Empty -> E.EventRel.empty
        | Unv -> Lazy.force ks.unv
        | v ->
            Warn.warn_always
              "Warning show: %s is not a relation: '%s'" x (pp_val v) ;
            raise Not_found in
        try
          rt_loc x (as_rel (Lazy.force (StringMap.find x env.vals)))
        with Not_found -> E.EventRel.empty in

      let doshowone x st =
        if O.showsome && StringSet.mem x  O.doshow then
          let show =
            lazy begin
              StringMap.add x
                (find_show_rel st.ks st.env x) (Lazy.force st.show)
            end in
          { st with show;}
        else st in

      let doshow bds st =
        let to_show =
          StringSet.inter O.doshow
            (StringSet.unions (List.map bdvars bds)) in
        if StringSet.is_empty to_show then st
        else
          let show = lazy begin
            StringSet.fold
              (fun x show  ->
                let r = find_show_rel st.ks st.env x in
                StringMap.add x r show)
              to_show
              (Lazy.force st.show)
          end in
          { st with show;} in

      let check_bell_enum =
        if O.bell then
          fun loc st name tags ->
            try
              if name = BellName.scopes then
                let bell_info = BellModel.add_rel name tags st.bell_info in
                { st with bell_info;}                  
              else if name = BellName.regions then
                let bell_info = BellModel.add_regions tags st.bell_info in
                { st with bell_info;}              
              else st
            with BellModel.Defined ->
              error st.silent loc "second definition of bell enum %s" name
        else
          fun _loc st _v _tags -> st in

(* Check if order is being defined by a "narrower" function *)
      let check_bell_order =
        if O.bell then
          let fun_as_rel f_order loc st id_tags id_fun =
(* This function evaluate all calls to id_fun on all tags in id_tags *)
            let env = from_st st in                  
            let cat_fun =
              try find_env_loc TxtLoc.none env id_fun
              with _ -> assert false in
            let cat_tags =
              let cat_tags =
                try StringMap.find id_tags env.EV.env.vals
                with Not_found ->
                  error false
                    loc "tag set %s must be defined while defining %s"
                    id_tags id_fun in
              match Lazy.force cat_tags with
              | V.ValSet ((TTag _|TAnyTag),scs) -> scs
              | v ->
                  error false loc "%s must be a tag set, found %s"
                    id_tags (pp_typ (type_val v)) in
            let order =
              ValSet.fold
                (fun tag order ->                        
                  let tgt =
                    try
                      eval_app loc { env with EV.silent=true;} cat_fun tag
                    with Misc.Exit -> V.Empty in
                  let tag = as_tag tag in
                  let add tgt order = StringRel.add (tag,as_tag tgt) order in
                  match tgt with
                  | V.Empty -> order
                  | V.Tag (_,_) -> add tgt order
                  | V.ValSet ((TTag _|TAnyTag),vs) ->
                      ValSet.fold add vs order
                  | _ ->
                      error false loc
                        "implicit call %s('%s) must return a tag, found %s"
                        id_fun tag (pp_typ (type_val tgt)))
                cat_tags StringRel.empty in
            let tags_set = as_tags cat_tags in
            let order = f_order order in
            if O.debug then begin
              warn loc "Defining hierarchy on %s from function %s"
                id_tags id_fun ;
              eprintf "%s: {%a}\n" id_tags
                (fun chan ->
                  StringSet.pp chan "," output_string) tags_set ;
              eprintf "hierarchy: %a\n"
                (fun chan ->
                  StringRel.pp chan " "
                    (fun chan (a,b) -> fprintf chan "(%s,%s)" a b))
                order
            end ;
            if not (StringRel.is_hierarchy tags_set order) then
              error false loc
                "%s defines the non-hierarchical relation %s"
                id_fun
                (BellModel.pp_order_dec order) ;
            try
              let bell_info =
                BellModel.add_order id_tags order st.bell_info in
              { st with bell_info;}
            with BellModel.Defined ->
              let old =
                try BellModel.get_order id_tags st.bell_info
                with Not_found -> assert false in
              if not (StringRel.equal old order) then
                error st.silent
                  loc "incompatible definition of order on %s by %s" id_tags id_fun ;
              st in

          fun bds st ->
            List.fold_left
              (fun st (_,pat,e) -> match pat with
              | Pvar v ->
                  if v = BellName.wider then
                    let loc = get_loc e in
                    fun_as_rel Misc.identity loc st BellName.scopes v
                  else if v = BellName.narrower then
                    let loc = get_loc e in
                    fun_as_rel StringRel.inverse loc st BellName.scopes v
                  else st
              | Ptuple _ -> st)
              st bds
        else fun _bds st -> st in

(* Evaluate test -> bool *)

      let eval_test check env t e = check (test2pred t (eval_rel env e)) in

      let make_eval_test = function
        | None -> fun _env -> true
        | Some (_,_,t,e,name) ->
            if skip_this_check name then
              fun _env -> true
            else
              fun env ->
                eval_test (check_through Check) env t e in

      let pp_check_failure st (loc,pos,_,e,_) =
        warn loc "check failed" ;
        show_call_stack st.loc ;
        if O.debug && O.verbose > 0 then begin
          let pp =
            try String.sub st.loc.txt pos.pos pos.len with _ -> assert false in
          let v = eval_rel (from_st st) e in
          let cy = E.EventRel.get_cycle v in
          U.pp_failure test st.ks.conc
            (sprintf "Failure of '%s'" pp)
            (let k = show_to_vbpp st in
            ("CY",E.EventRel.cycle_option_to_rel cy)::k)
        end in
(* Execute one instruction *)

      let eval_st st e = eval (from_st st) e in

      let rec exec : 'a. 'a st -> ins -> ('a st -> 'a -> 'a) -> 'a -> 'a  =
      fun  (type res) st i kont (res:res) ->  match i with
      | Debug (_,e) ->
          if O.debug then begin
            let v = eval_st st e in
            eprintf "%a: value is %a\n%!"
              TxtLoc.pp (get_loc e) debug_val v
          end ;
          kont st res
      | Show (_,xs) when not O.bell ->
          if O.showsome then
            let show = lazy begin
              List.fold_left
                (fun show x ->
                  StringMap.add x (find_show_rel st.ks st.env x) show)
                (Lazy.force st.show) xs
            end in
            kont { st with show;} res
          else kont st res
      | UnShow (_,xs) when not O.bell ->
          if O.showsome then
            let show = lazy begin
              List.fold_left
                (fun show x -> StringMap.remove x show)
                (Lazy.force st.show)
                (StringSet.(elements (diff (of_list xs) O.doshow)))
            end in
            kont { st with show;} res
          else kont st res
      | ShowAs (_,e,id) when not O.bell  ->
          if O.showsome then
            let show = lazy begin
              StringMap.add id
                (rt_loc id (eval_rel (from_st st) e)) (Lazy.force st.show)
            end in
            kont { st with show; } res
          else kont st res
      | Test (tst,ty) when not O.bell  ->
          exec_test st tst ty kont res
      | Let (_loc,bds) ->
          let env = eval_bds (from_st st) bds in
          let st = { st with env; } in
          let st = doshow bds st in
          let st = check_bell_order bds st in
          kont st res
      | Rec (loc,bds,testo) ->        
          let env =
            match
              env_rec
                (make_eval_test testo) (from_st st)
                loc (fun pp -> pp@show_to_vbpp st) bds
            with
            | CheckOk env -> Some env
            | CheckFailed env ->
              if O.debug then begin
                let st = { st with env; } in
                let st = doshow bds st in
                pp_check_failure st (Misc.as_some testo)
              end ;
                None in
          begin match env with
          | None -> res
          | Some env ->
              let st = { st with env; } in
              let st = doshow bds st in
(* Check again for strictskip *)
              let st = match testo with
              | None -> st
              | Some (_,_,t,e,name) ->
                  if
                    O.strictskip &&
                    skip_this_check name &&
                    not (eval_test Misc.identity (from_st st) t e)
                  then begin
                    { st with
                      skipped =
                      StringSet.add (Misc.as_some name) st.skipped;}
                  end else st in
(* Check bell definitions *)
              let st = check_bell_order bds st in
              kont st res
          end
      | Include (loc,fname) ->
          do_include loc fname st kont res
      | Procedure (_,name,args,body) ->
          let p =
            Proc { proc_args=args; proc_env=st.env; proc_body=body; } in
          kont { st with env = add_val name (lazy p) st.env } res
      | Call (loc,name,es,tname) when not O.bell ->
          let skip = skip_this_check tname in
          if O.debug && skip then
            warn loc "skipping call: %s" (Misc.as_some tname) ;
          if skip && not O.strictskip then (* won't call *)
            kont st res
          else (* will call *)
            let env0 = from_st st
            and show0 = st.show in
            let p = protect_call st (eval_proc loc env0) name in
            let env1 =
              protect_call st
                (fun penv ->
                  add_args loc p.proc_args (eval env0 es) env0 penv)
                p.proc_env in
            if skip then (* call for boolean... *)
                let tval = 
                  let benv = purge_env st.silent loc env1 in
                  run { (push_loc st (loc,tname)) with env=benv; } p.proc_body
                    (fun _ _ -> true) false in
                if tval then kont st res
                else
                  kont
                    { st with skipped =
                      StringSet.add (Misc.as_some tname) st.skipped;}
                    res
            else
              let st = push_loc st (loc,tname) in            
              run { st with env = env1; } p.proc_body
                (fun st_call res ->
                  let st_call = pop_loc st_call in
                  kont { st_call with env = st.env ; show=show0;} res)
              res
      | Enum (loc,name,xs) ->
          let env = st.env in
          let tags =
            List.fold_left
              (fun env x -> StringMap.add x name env)
              env.tags xs in
          let enums = StringMap.add name xs env.enums in
(* add a set of all tags... *)
          let alltags =
            lazy begin
              let vs =
                List.fold_left
                  (fun k x -> ValSet.add (V.Tag (name,x)) k)
                  ValSet.empty xs in
              V.ValSet (TTag name,vs)
            end in
          let env = add_val name alltags env in
          if O.debug && O.verbose > 1 then
            warn loc "adding set of all tags for %s" name ;
          let env = { env with tags; enums; } in
          let st = { st with env;} in
          let st = check_bell_enum loc st name xs in
          kont st res
      | Forall (_loc,x,e,body) when not O.bell  ->
          let st0 = st in
          let env0 = st0.env in
          let v = eval (from_st st0) e in
          begin match tag2set v with
          | V.Empty -> kont st res
          | ValSet (_,set) ->
              let rec run_set st vs res =
                if ValSet.is_empty vs then
                  kont st res
                else
                  let v =
                    try ValSet.choose vs
                    with Not_found -> assert false in
                  let env = add_val x (lazy v) env0 in
                  run { st with env;} body
                    (fun st res ->
                      run_set { st with env=env0;} (ValSet.remove v vs) res)
                    res in
              run_set st set res
          | _ ->
              error st.silent
                (get_loc e) "forall instruction applied to non-set value"
          end
      | WithFrom (loc,x,e) when not O.bell  ->
          let st0 = st in
          let env0 = st0.env in
          let v = eval (from_st st0) e in
          begin match v with
          | V.Empty -> res
          | ValSet (_,vs) ->
              ValSet.fold
                (fun v res ->
                  let env = add_val x (lazy v) env0 in
                  kont (doshowone x {st with env;}) res)
                vs res
          | Clo _ ->
              let kv =
                Kont
                  ((fun v (res:res) ->
                    let env = add_val x (lazy v) env0 in
                    kont (doshowone x {st with env;}) res),
                  res) in
              begin match eval_app loc (from_st st) v kv with
              | Kont (_,res) -> res
              | v -> 
                  error
                    st.silent (get_loc e)
                    "improper generator, returns %s"
                    (pp_val v)
              end
          | _ -> error st.silent (get_loc e) "set or generator expected"
          end
      | Latex _ -> kont st res
      | Events (loc,x,es,def) when O.bell ->
          if not (StringSet.mem x BellName.all_sets) then
            error st.silent loc
              "event type %s is not part of legal {%s}\n"
              x (StringSet.pp_str "," Misc.identity BellName.all_sets) ;
	  let vs = List.map (eval_loc (from_st st)) es in
	  let event_sets =
            List.map
              (fun (loc,v) -> match v with 
	      | ValSet((TTag _|TAnyTag),elts) -> 
                  let tags = 
	            ValSet.fold
                      (fun elt k -> as_tag elt::k)
                      elts [] in
                  StringSet.of_list tags
              | V.Tag (_,tag) -> StringSet.singleton tag
              | _ ->
                  error false loc
                    "event declaration expected a set of tags, found %s"
                    (pp_val v))
              vs in
          let bell_info =
            BellModel.add_events x event_sets st.bell_info in
          let bell_info =
            if def then 
              let defarg =
                List.map2 
                  (fun ss e -> match StringSet.as_singleton ss with
                 | None ->
                     error st.silent (get_loc e) "ambiguous default declaration"
                 | Some a -> a) event_sets es in
              try BellModel.add_default x defarg bell_info
              with BellModel.Defined ->
                error st.silent loc "second definition of default for %s" x
            else bell_info in
          let st = { st with bell_info;} in
	  kont st res
      | Events _ ->
          assert (not O.bell) ;
          kont st res (* Ignore bell constructs when executing model *)
      | Test _|UnShow _|Show _|ShowAs _
      | Call _|Forall _
      | WithFrom _ ->
          assert O.bell ;
          kont st res (* Ignore cat constructs when executing bell *)

      and exec_test :
        'a. 'a st -> app_test -> test_type ->
          ('a st -> 'a -> 'a) -> 'a -> 'a =
        fun st (loc,_,t,e,name as tst) test_type kont res ->
        let skip = skip_this_check name in
        if O.debug &&  skip then
          warn loc "skipping check: %s" (Misc.as_some name) ;
        if
          O.strictskip || not skip
        then
          let ok = eval_test (check_through test_type) (from_st st) t e in
          if ok then
            match test_type with 
            | Check|UndefinedUnless -> kont st res
            | Flagged -> 
                begin match name with
                | None ->
                    warn loc "this flagged test does not have a name" ;
                    kont st res
                | Some name ->
                    if O.debug then
                      warn loc "flag %s recorded" name ;
                    kont
                      {st with flags=
                       Flag.Set.add (Flag.Flag name) st.flags;}
                      res
                end
          else if skip then begin
            assert O.strictskip ;
            kont
              { st with
                skipped = StringSet.add (Misc.as_some name) st.skipped;}
              res
          end else begin
            match test_type with
            | Check ->
                if O.debug then pp_check_failure st tst ;
                res
            | UndefinedUnless ->
                kont {st with flags=Flag.Set.add Flag.Undef st.flags;} res
            | Flagged -> kont st res
          end
        else begin
          W.warn "Skipping check %s" (Misc.as_some name) ;
          kont st res
        end

      and do_include : 'a . TxtLoc.t -> string -> 'a st ->
        ('a st -> 'a -> 'a) -> 'a -> 'a =
      fun loc fname st kont res ->
        (* Run sub-model file *)
        if O.debug then warn loc "include \"%s\"" fname ;
        let module P =
          ParseModel.Make
            (struct
              include LexUtils.Default 
              let libfind = O.libfind
            end) in
        let txt0 = st.loc.txt in
        let txt,(_,_,iprog) =
          try P.parse fname
          with Misc.Fatal msg | Misc.UserError msg ->
            error st.silent loc "%s" msg  in
        run {st with loc = { st.loc with txt;}; } iprog
          (fun st res ->
            let loc = { st.loc with txt=txt0; } in
            kont { st with loc; } res)
          res

      and run : 'a. 'a st -> ins list -> ('a st -> 'a -> 'a) -> 'a -> 'a =
      fun st c kont res -> match c with
      | [] ->  kont st res
      | i::c ->
          exec st i
            (fun st res -> run st c kont res)
            res in

      fun ks m vb_pp kont res ->
(* Primitives *)
        let m = add_primitives (env_from_ienv m) in
(* Initial show's *)
        let show =
          if O.showsome then
            lazy begin
              let show =
                List.fold_left
                  (fun show (tag,v) -> StringMap.add tag v show)
                  StringMap.empty (Lazy.force vb_pp) in
              StringSet.fold
                (fun tag show -> StringMap.add tag (find_show_rel ks m tag) show)
                O.doshow show
            end else lazy StringMap.empty in

        let st =
          {env=m; show=show; skipped=StringSet.empty;
           silent=false; flags=Flag.Set.empty;
           ks; bell_info=BellModel.empty_info;
           loc={stack =[]; txt=prog_txt;}} in        

        let kont st res =  kont (st2out st) res in          

        let just_run st res = run st prog kont res in
        do_include TxtLoc.none "stdlib.cat" st
          (match O.bell_fname with
          | None -> just_run (* No bell file, just run *)
          | Some fname ->
            fun st res ->
              do_include TxtLoc.none fname st just_run res)
          res

  end
