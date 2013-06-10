open List
open Classifier
open NetCoreEval0x04

let __ = let rec f _ = Obj.repr f in Obj.repr f

let second f = function
| (a, b) -> (a, (f b))

let rec compile_pred opt pr sw =
  match pr with
  | PrHdr pat -> [(pat, true)]
  | PrOnSwitch sw' ->
    if sw = sw' then [(Pattern.Pattern.all, true)] else []
  | PrOr (pr1, pr2) ->
    opt (union (||) (compile_pred opt pr1 sw) (compile_pred opt pr2 sw))
  | PrAnd (pr1, pr2) ->
    opt (inter (&&) (compile_pred opt pr1 sw) (compile_pred opt pr2 sw))
  | PrNot pr' ->
    opt
      (map (second not)
         ((compile_pred opt pr' sw) @ [(Pattern.Pattern.all, false)]))
  | PrAll -> [(Pattern.Pattern.all, true)]
  | PrNone -> []

let apply_act a = function
| true -> a
| false -> []

module Gen =
struct
  let g = ref (Int32.of_int 0)
  let next_val () =     
    let v = !g in
    g := Int32.succ !g;
    v
end

let rec compile_pol opt popt p sw =
  match p with
  | PoAtom (pr, act0) ->
    (opt
       (map (second (apply_act act0))
          ((compile_pred popt pr sw) @
              [(Pattern.Pattern.all,false)])),
     [])
  | PoUnion (pol1, pol2) ->
    let p1,g1 = compile_pol opt popt pol1 sw in
    let p2,g2 = compile_pol opt popt pol2 sw in
    (opt
       (union List.append p1 p2),
     List.append g1 g2)
  | PoOpt (pr, act0) ->
    let gid = Gen.next_val () in
    (opt
       (map (second (apply_act [Group gid]))
          (List.append (compile_pred popt pr sw)
             [(Pattern.Pattern.all,false)])),
     [(gid, OpenFlowTypes.FF, List.map (fun x -> [x]) act0)])


(** val strip_empty_rules : 'a1 coq_Classifier -> 'a1 coq_Classifier **)

let rec strip_empty_rules = function
| [] -> []
| p::cf0 ->
  let pat,acts = p in
  if Pattern.Pattern.is_empty pat
  then strip_empty_rules cf0
  else (pat,acts)::(strip_empty_rules cf0)

(** val no_opt : 'a1 coq_Classifier -> 'a1 coq_Classifier **)

let no_opt = fun x -> x

(** val compile_no_opt : pol -> switchId -> act list coq_Classifier **)

let compile_no_opt =
  compile_pol no_opt

(** val compile_opt : pol -> switchId -> act list coq_Classifier **)


let get_groups ft = List.fold_left (fun acc (_, acts) ->
  (List.fold_left (fun acc act -> match act with
    | Group gid -> gid :: acc
    | _ -> acc) [] acts) @ acc) [] ft

let rec trim_gt ft gt = 
  let groups = get_groups ft in
  List.filter (fun (gid, _,_) -> List.mem gid groups) gt

let compile_opt pol swid =
  (* compile_pol (fun x -> strip_empty_rules (elim_shadowed x)) (fun x -> strip_empty_rules (elim_shadowed x)) pol swid *)
  (* MJR: We generate way too many group table entries. This is a hack
     to eliminate the unused ones. The right way is to fix the compilation
     alg, but not going to happen right now *)
  let ft, gt = compile_pol (fun x -> strip_empty_rules (elim_shadowed x)) (fun x -> strip_empty_rules (elim_shadowed x)) pol swid in
  (ft, trim_gt ft gt)

