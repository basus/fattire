open Printf
open Lwt
module PolGen = NetCorePolicyGen

(* Add new policies here. Nothing else should need to change. *)
let select_policy mn graph (name : string) = 
  let open NetCoreSyntax in
  let open NetCorePolicyGen in
  match name with
    | "sp" -> 
      let pol = all_pairs_shortest_paths graph in
      let exp () = 
        Lwt_unix.sleep 2.0 >>
        Lwt_list.iter_s (fun _ -> Mininet.ping_all mn (hosts graph) >> return ())
        [1;2;3;4;5;6] in
      (pol, exp)
    | "bc" ->
      let pol = Par (all_pairs_shortest_paths graph, 
                     all_broadcast_trees graph) in
      let exp () =
        let hosts = hosts graph in
        Lwt_unix.sleep 2.0 >>
        Lwt_list.iter_s (Mininet.enable_broadcast_ping mn) hosts >>
        Lwt_list.iter_s (Mininet.broadcast_ping mn 10) hosts
      in (pol, exp)
    | str -> failwith ("invalid policy: " ^ str)


let custom = ref None
let topo = ref "tree,2,2"
let policy_name = ref "sp"
let use_flow_mod = ref false
let pcap_file = ref None

let make_default_pcap_filename () =
    let ctrl = if !use_flow_mod then "flowmod" else "pktout" in
    sprintf "%s-%s-%s.pcap" ctrl !policy_name !topo


let _ =
  Arg.parse
    [("-flowmod",
      Arg.Unit (fun () -> use_flow_mod := true),
      "send FlowMod messages (defaults to PktOut)");
     ("-custom",
      Arg.String (fun str -> custom := Some str),
      "custom topology file for Mininet");
     ("-topo", 
      Arg.String (fun str -> topo := str),
      "topology string for Mininet");
     ("-policy",
      Arg.String (fun str -> policy_name := str),
      "sp (all pairs shortest paths)");
     ("-pcap",
      Arg.String (fun str -> pcap_file := Some str),
      "Save tcpdump of 6633 and icmp");
     ("-autopcap",
      Arg.Unit (fun () -> pcap_file := Some (make_default_pcap_filename ())),
      "Save tcpdump of 6633 and icmp")
    ]
    (fun str -> failwith ("invalid argument " ^ str))
    "Usage: Main_Verified.native -topo <filename> -policy <policy-name>"

let start_tcpdump (pcap_file : string) : unit = 
  let pid = 
    Unix.create_process "sudo"
      [| "sudo"; "tcpdump"; "-w"; pcap_file; "-i"; "any"; 
         "-B"; string_of_int (1024 * 50);
         "(tcp port 6633) or icmp" |]
      Unix.stdin Unix.stdout Unix.stderr in
  let sigint_tcpdump () = 
    Unix.kill pid Sys.sigint;
    (* Let tcpdump finish and close the pcap file before we read it back. *)
    let _ = Unix.waitpid [] pid in
    let _ = Unix.system ("capinfos " ^ pcap_file) in
    () in
  at_exit sigint_tcpdump

let main = 
  lwt mn = Mininet.create_mininet_process (?custom:!custom) !topo in
  lwt net = Mininet.net mn in
  let graph = PolGen.from_mininet_raw net in
  let module Policy = struct
    let switches = PolGen.switches graph
    let (policy, experiment) = select_policy mn graph !policy_name
  end in
  eprintf "[VerifiedBenchmark.ml] Linking controller to policy\n%!";
  let module Controller = 
        VerifiedNetCore.Make (Platform.OpenFlowPlatform) (Policy) in
  eprintf "[VerifiedBenchmark.ml] Building initial controller state\n%!";
  let init = match !use_flow_mod with
    | true -> Controller.init_flow_mod ()
    | false -> Controller.init_packet_out () in
  eprintf "[VerifiedBenchmark.ml] Launching tcpdump (if -pcap set)\n%!";
  let _ = match !pcap_file with
    | None -> ()
    | Some fname -> start_tcpdump fname in
  let _ = Platform.OpenFlowPlatform.init_with_port 6633 in
  Lwt_io.eprintf "[VerifiedBenchmarks.ml] Starting controller.\n" >>
  lwt _ = Controller.start init in
  Lwt_io.eprintf "[VerifiedBenchmarks.ml] Invoking experiment.\n" >>
  lwt _ = Policy.experiment () in
  return ()

let _ = Lwt_main.run main in ()
                  

    