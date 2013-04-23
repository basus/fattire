open Datatypes
open List0
open Packet
open OpenFlowTypes
open WordInterface
open NetCoreEval

type id = int

type modification = NetCoreEval.modification
let modifyTpDst = NetCoreEval.modifyTpDst
let modifyTpSrc = NetCoreEval.modifyTpSrc
let modifyNwTos = NetCoreEval.modifyNwTos
let modifyNwDst = NetCoreEval.modifyNwDst
let modifyNwSrc = NetCoreEval.modifyNwSrc
let modifyDlVlanPcp = NetCoreEval.modifyDlVlanPcp
let modifyDlVlan = NetCoreEval.modifyDlVlan
let modifyDlDst = NetCoreEval.modifyDlDst
let modifyDlSrc = NetCoreEval.modifyDlSrc
let modification_rec = NetCoreEval.modification_rec
let modification_rect = NetCoreEval.modification_rect
let unmodified = NetCoreEval.unmodified

type act =
| Forward of modification * pseudoPort
| Group of groupId
| ActGetPkt of id

type pol =
| PoAtom of pred * act list
| PoUnion of pol * pol

type input =
| InPkt of switchId * portId * packet * bufferId option

type output =
| OutAct of switchId * act list * packet * (bufferId, bytes) sum
| OutGetPkt of id * switchId * portId * packet
| OutNothing

let pp_to_13pp pp = match pp with
  | OpenFlow0x01Types.PhysicalPort p -> PhysicalPort (Int32.of_int p)
  | OpenFlow0x01Types.InPort -> InPort
  | OpenFlow0x01Types.Flood -> Flood
  | OpenFlow0x01Types.AllPorts -> AllPorts
  | OpenFlow0x01Types.Controller x -> Controller x

let eval_to_eval13 act = match act with
  | NetCoreEval.Forward (a,b) -> Forward (a,pp_to_13pp b)
  | NetCoreEval.ActGetPkt a -> ActGetPkt a

let rec convert_from_eval10 pol = match pol with 
  | NetCoreEval.PoAtom (pred,acts) -> 
    PoAtom (pred, List.map eval_to_eval13 acts)
  | NetCoreEval.PoUnion(pol1,pol2) -> 
    PoUnion(convert_from_eval10 pol1, convert_from_eval10 pol2)

let maybe_modify newVal modifier pk =
  match newVal with
  | Some v -> modifier pk v
  | None -> pk

(** val withVlanNone : dlVlan option option -> dlVlan option **)

let withVlanNone = function
| Some y ->
  (match y with
   | Some n -> Some n
   | None -> Some OpenFlow0x01Types.coq_VLAN_NONE)
| None -> None

(** val modify_pkt : modification -> packet -> packet **)

let modify_pkt mods pk =
  let { modifyDlSrc = dlSrc; modifyDlDst = dlDst; modifyDlVlan = dlVlan0;
    modifyDlVlanPcp = dlVlanPcp0; modifyNwSrc = nwSrc; modifyNwDst = nwDst;
    modifyNwTos = nwTos0; modifyTpSrc = tpSrc; modifyTpDst = tpDst } = mods
  in
  maybe_modify dlSrc setDlSrc
    (maybe_modify dlDst setDlDst
      (maybe_modify (withVlanNone dlVlan0) setDlVlan
        (maybe_modify dlVlanPcp0 setDlVlanPcp
          (maybe_modify nwSrc setNwSrc
            (maybe_modify nwDst setNwDst
              (maybe_modify nwTos0 setNwTos
                (maybe_modify tpSrc setTpSrc
                  (maybe_modify tpDst setTpDst pk))))))))


(** val classify : pol -> input -> output list **)

(* Need to strip out the controller actions so that we don't cycle packets between the switch and controller *)

let rec strip_controller acts = match acts with
  | Forward (a, (Controller x)) :: acts -> strip_controller acts
  | ActGetPkt x :: acts -> strip_controller acts
  | a :: acts -> a :: strip_controller acts
  | [] -> []

let eval_action inp = function
| Forward (mods, pp) ->
  let InPkt (sw, p, pk, buf) = inp in
  OutAct (sw, [Forward (mods, pp)], pk,
	  (match buf with
	    | Some b -> Coq_inl b
	    | None -> Coq_inr (serialize_pkt pk)))
| ActGetPkt x ->
  let InPkt (sw, pt, pk, buf) = inp in OutGetPkt (x, sw, pt, pk)

(* [OutAct (sw, (strip_controller actions), pk, match buf with *)
(*       | Some b -> Coq_inl b *)
(*       | None -> Coq_inr (Cstruct.to_string (serialize_pkt pk)))] else [] *)

let rec classify p inp =
  match p with
  | PoAtom (pr, actions) ->
    let InPkt (sw, pt, pk, buf) = inp in
    if match_pred pr sw (Int32.to_int pt) pk then map (eval_action inp) actions else []
  | PoUnion (p1, p2) -> app (classify p1 inp) (classify p2 inp)
