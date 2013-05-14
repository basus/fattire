open Classifier
open ControllerInterface0x04
open Datatypes
open List0
open NetCoreEval
open NetCoreEval0x04
open NetCoreCompiler0x04
open NetworkPacket
open OpenFlowTypes
open Types
open WordInterface

(** val prio_rec :
    Word16.t -> 'a1 coq_Classifier -> ((Word16.t*Pattern.pattern)*'a1) list **)

let nc_compiler = NetCoreCompiler0x04.compile_opt

let rec prio_rec prio = function
| [] -> []
| p::rest ->
  let pat,act0 = p in ((prio,pat),act0)::(prio_rec (Word16.pred prio) rest)

(** val prioritize :
    'a1 coq_Classifier -> ((Word16.t*Pattern.pattern)*'a1) list **)

let prioritize lst =
  prio_rec Word16.max_value lst

(** val packetIn_to_in : switchId -> packetIn -> input **)

let packetIn_to_in sw pktIn =
  let inport = List.fold_left (fun acc x -> (match x with 
    | OxmInPort p -> p 
    | _ -> acc)) (Int32.of_int 0) pktIn.pi_ofp_match in
  let pkt = (match pktIn.pi_pkt with
    | Some pkt -> pkt) in
  InPkt (sw, inport, pkt, pktIn.pi_buffer_id)

(** val maybe_openflow0x01_modification :
    'a1 option -> ('a1 -> action) -> actionSequence **)

let maybe_openflow0x01_modification newVal mkModify =
  match newVal with
  | Some v -> (mkModify v)::[]
  | None -> []

(** val modification_to_openflow0x01 : modification -> actionSequence **)

(* TODO: just omitting most mods (NW_SRC etc) because 1.3 parser is a little behind *)
let modification_to_openflow0x01 mods =
  let { modifyDlSrc = dlSrc; modifyDlDst = dlDst; modifyDlVlan = dlVlan;
    modifyDlVlanPcp = dlVlanPcp; modifyNwSrc = nwSrc; modifyNwDst = nwDst;
    modifyNwTos = nwTos; modifyTpSrc = tpSrc; modifyTpDst = tpDst } = mods
  in
  app (maybe_openflow0x01_modification dlSrc (fun x -> SetField (OxmEthSrc (val_to_mask x))))
    (maybe_openflow0x01_modification dlDst (fun x -> SetField (OxmEthDst (val_to_mask x))))
        (* (match dlVlan with *)
	(*   | Some None -> [PopVlan] *)
	(*   | Some (Some n) -> [PushVlan;SetField (OxmVlanVId (val_to_mask n))] *)
	(*   | None -> [])) *)

(** val translate_action : portId option -> act -> actionSequence **)

let translate_action in_port = function
| Forward (mods, p) ->
  (match p with
   | PhysicalPort pp ->
     app (modification_to_openflow0x01 mods)
       ((match in_port with
         | Some pp' ->
           if pp' = pp
           then Output InPort
           else Output (PhysicalPort pp)
         | None -> Output (PhysicalPort pp))::[])
   | _ -> app (modification_to_openflow0x01 mods) ((Output p)::[]))
| ActGetPkt x -> (Output (Controller Word16.max_value))::[]

(** val to_flow_mod : priority -> Pattern.pattern -> act list -> flowMod **)

let wildcard_to_mask wc def =
  match wc with
    | Wildcard.WildcardExact a -> val_to_mask a
    | Wildcard.WildcardAll -> {m_value = def; m_mask = Some def}
    | Wildcard.WildcardNone -> {m_value = def; m_mask = Some def}

let pattern_to_oxm_match pat = 
  let { PatternImplDef.ptrnDlSrc = dlSrc;
        ptrnDlDst = dlDst;
        ptrnDlType = dlTyp;
        ptrnDlVlan = dlVlan;
        ptrnDlVlanPcp = dlVlanPcp;
        ptrnNwSrc = nwSrc;
        ptrnNwDst = nwDst;
        ptrnNwProto = nwProto;
        ptrnNwTos = nwTos;
        ptrnTpSrc = tpSrc;
        ptrnTpDst = tpDst;
        ptrnInPort = inPort } = pat in
  (* 0 is the all wildcard *)
  ((match dlSrc with Wildcard.WildcardExact a -> [OxmEthSrc (val_to_mask a)] | _ -> [])
   @ (match dlTyp with Wildcard.WildcardExact t -> [OxmEthType t] | _ -> [])
   @ (match dlDst with Wildcard.WildcardExact a -> [ OxmEthDst (val_to_mask a)] | _ -> [])
   (* @ (match dlVlan with  *)
   (*   | Wildcard.WildcardExact a -> [ OxmVlanVId (val_to_mask a)]  *)
   (*   (\* Must be empty list. Trying to get cute and use a wildcard mask confuses the switch *\) *)
   (*   | Wildcard.WildcardAll -> [] *)
   (*   | Wildcard.WildcardNone -> [OxmVlanVId {value=0; mask=None}]) *)
   (* (\* VlanPCP requires exact non-VLAN_NONE match on Vlan *\) *)
   (* @ (match (dlVlanPcp, dlVlan) with (Wildcard.WildcardExact a, Wildcard.WildcardExact _) -> [ OxmVlanPcp a] | _ -> []) *)
   @ (match nwSrc with Wildcard.WildcardExact a -> [ OxmIP4Src (val_to_mask a)] | _ -> [])
   @ (match nwDst with Wildcard.WildcardExact a -> [ OxmIP4Dst (val_to_mask a)] | _ -> [])
   @ (match inPort with Wildcard.WildcardExact p -> [OxmInPort (Int32.of_int p)] | _ -> []),
  (* If IP addrs are set, must be IP EthType. Predicate not currently in compiler *)
   (* @ (match (nwSrc, nwDst) with  *)
   (*   | (Wildcard.WildcardExact t, _) *)
   (*   | (_, Wildcard.WildcardExact t) -> [OxmEthType 0x800]  *)
   (*   | (_,_) -> []) *)
   match inPort with
     | Wildcard.WildcardExact p -> Some (Int32.of_int p)
     | _ -> None)

let to_flow_mod prio pat act0 tableId =
  let ofMatch,inport = pattern_to_oxm_match pat in
  { mfTable_id = tableId; mfCommand = AddFlow; mfOfp_match = ofMatch; mfPriority = prio; 
    mfInstructions = [ApplyActions (concat_map (translate_action inport) act0)]; 
    mfCookie = val_to_mask (Int64.of_int 0); mfIdle_timeout = Permanent; 
    mfHard_timeout = Permanent; mfOut_group = None;
  mfFlags = {  fmf_send_flow_rem = false; 
	     fmf_check_overlap = false; 
	     fmf_reset_counts = false; 
	     fmf_no_pkt_counts = false;
	     fmf_no_byt_counts = false }; 
  mfBuffer_id = None; mfOut_port = None}

(** val flow_mods_of_classifier : act list coq_Classifier -> flowMod list **)

let flow_mods_of_classifier lst tblId =
  fold_right (fun ppa lst0 ->
    let p,act0 = ppa in
    let prio,pat = p in
    if Pattern.Pattern.is_empty pat
    then lst0
    else (to_flow_mod prio pat act0 tblId)::lst0) [] (prioritize lst)

let rec get_watch_port acts = match acts with
  | Forward (_, PhysicalPort pp) :: acts -> Some pp
  | a :: acts -> get_watch_port acts
  | [] -> None

let to_group_mod gid gtype bkts =
  AddGroup (gtype, gid, map (fun acts -> {bu_weight = 0;
					  bu_watch_port = get_watch_port acts;
					  bu_watch_group = None;
					  bu_actions = (concat_map (translate_action None) acts)}) 
    bkts)

(** val flow_mods_of_classifier : act list coq_Classifier -> flowMod list **)

let group_mods_of_classifier lst =
  map (fun (x1,x2,x3) -> to_group_mod x1 x2 x3) lst

(** val delete_all_flows : flowMod **)
let delete_all_groups = 
  DeleteGroup (All,OpenFlow0x04Parser.ofpg_all)

let delete_all_flows tableId =
  { mfCommand = DeleteFlow; mfOfp_match = []; mfPriority = 0;
    mfTable_id = tableId; mfBuffer_id = None; mfOut_port = None;
    mfOut_group = None; mfInstructions = []; 
    mfCookie = val_to_mask (Int64.of_int 0); mfIdle_timeout = Permanent;
    mfHard_timeout = Permanent;
  mfFlags = {  fmf_send_flow_rem = false; 
	     fmf_check_overlap = false; 
	     fmf_reset_counts = false; 
	     fmf_no_pkt_counts = false;
	     fmf_no_byt_counts = false }}

type group_htbl = (OpenFlowTypes.switchId, (int32 * OpenFlowTypes.groupType * NetCoreEval0x04.act list list) list) Hashtbl.t

module type NETCORE_MONAD = 
 sig 
  type 'x m 
  
  val bind : 'a1 m -> ('a1 -> 'a2 m) -> 'a2 m
  
  val ret : 'a1 -> 'a1 m

  type state = { policy : pol; switches : switchId list }

  (** val policy : ncstate -> pol **)

  val policy : state -> pol

  (** val switches : ncstate -> switchId list **)

  val switches : state -> switchId list
  
  val get : state m
  
  val put : state -> unit m
  
  val send : switchId -> xid -> message -> unit m
  
  val recv : event m
  
  val forever : unit m -> unit m
  
  val handle_get_packet : id -> switchId -> portId -> packet -> unit m
 end

module Make = 
 functor (Monad:NETCORE_MONAD) ->
 struct 
  (** val sequence : unit Monad.m list -> unit Monad.m **)
  
  let rec sequence = function
  | [] -> Monad.ret ()
  | cmd::lst' -> Monad.bind cmd (fun x -> sequence lst')
  
  (** val config_commands : pol -> switchId -> unit Monad.m **)

  let groups_to_string groups =
    String.concat ";\n" (List.map (fun (gid,_,acts) -> Printf.sprintf "\t%ld" gid) groups)

  let group_htbl_to_str ghtbl =
    String.concat "" (Hashtbl.fold (fun sw groups acc -> (Printf.sprintf "%Ld -> [\n%s]\n" sw (groups_to_string groups)):: acc) ghtbl [])
  
  let config_commands (pol0 :pol) swId tblId =
    Printf.printf "[NetCoreController0x04.ml] config_commands %Ld %s\n%!" swId (pol_to_string pol0);
    let fm_cls, gm_cls = nc_compiler pol0 swId in
    Printf.printf "[NetCoreController0x04.ml] installing ft of size %d %s\n%!" (List.length fm_cls) (cls_to_string fm_cls);
    sequence
      ((map (fun fm -> Monad.send swId Word32.zero (GroupModMsg fm))
	  (delete_all_groups :: (group_mods_of_classifier gm_cls))) @
      (map (fun fm -> Monad.send swId Word32.zero (FlowModMsg fm))
        (delete_all_flows tblId::(flow_mods_of_classifier fm_cls tblId))))
  
  (** val set_policy : pol -> unit Monad.m **)
  
  (* FIXME: Default tableId of 0 *)
  let set_policy (pol0 : pol) =
    Monad.bind Monad.get (fun st ->
      let switch_list = st.Monad.switches in
      Monad.bind (Monad.put { Monad.policy = pol0; Monad.switches = switch_list })
        (fun x ->
        Monad.bind (sequence (map (fun sw -> config_commands pol0 sw 0) switch_list))
          (fun x0 -> Monad.ret ())))
  
  (** val handle_switch_disconnected : switchId -> unit Monad.m **)
  
  let handle_switch_disconnected swId =
    Monad.bind Monad.get (fun st ->
      let switch_list =
        filter (fun swId' ->
          if Word64.eq_dec swId swId' then false else true) st.Monad.switches
      in
      Monad.bind (Monad.put { Monad.policy = st.Monad.policy; Monad.switches = switch_list })
        (fun x -> Monad.ret ()))
  
  (** val handle_switch_connected : switchId -> unit Monad.m **)
  
  let handle_switch_connected swId =
    Monad.bind Monad.get (fun st ->
      Monad.bind
        (Monad.put { Monad.policy = st.Monad.policy; Monad.switches = (swId::st.Monad.switches) })
        (fun x ->
        Monad.bind (config_commands st.Monad.policy swId 0) (fun x0 -> Monad.ret ())))
  
  (** val send_output : output -> unit Monad.m **)

  let send_output = function
  | OutAct (swId, [], pkt, bufOrBytes) -> Monad.ret ()
  | OutAct (swId, acts, pkt, bufOrBytes) ->
    let (buf, pkt) = (match bufOrBytes with Coq_inl buf -> (Some buf, None) | _ -> (None, Some pkt)) in
    Monad.send swId Word32.zero (PacketOutMsg { po_buffer_id =
      buf; po_in_port = Controller 0; po_pkt = pkt; po_actions = concat_map (translate_action None) acts })
  | OutGetPkt (x, switchId0, portId0, packet0) ->
    Monad.handle_get_packet x switchId0 portId0 packet0
  | OutNothing -> Monad.ret ()
  
  (** val handle_packet_in : switchId -> packetIn -> unit Monad.m **)
  
  let handle_packet_in swId pk = 
    Monad.bind Monad.get (fun st ->
      let policy = st.Monad.policy in
      let outs = classify policy (packetIn_to_in swId pk) in
      sequence (map send_output outs))
  
  (** val handle_event : event -> unit Monad.m **)
  
  let handle_event = function
  | SwitchConnected swId -> 
    Printf.printf "[NetCoreController0x04.ml] SwitchConnected %Ld\n%!" swId;
    handle_switch_connected swId
  | SwitchDisconnected swId -> 
    Printf.printf "[NetCoreController0x04.ml] SwitchDisconnected %Ld\n%!" swId;
    handle_switch_disconnected swId
  | SwitchMessage (swId, xid0, msg) ->
    Printf.printf "[NetCoreController0x04.ml] SwitchMessage event %Ld\n%!" swId;
    (match msg with
     | PacketInMsg pktIn -> handle_packet_in swId pktIn
     | _ -> Monad.ret ())
  
  (** val main : unit Monad.m **)
  
  let main =
    Monad.forever (Monad.bind Monad.recv (fun evt -> handle_event evt))
 end

