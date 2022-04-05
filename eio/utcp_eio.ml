let src = Logs.Src.create "tcp.mirage" ~doc:"TCP mirage"
module Log = (val Logs.src_log src : Logs.LOG)

module type Ip_wrap = sig
  include Tcpip.Ip.S
  val to_ipaddr : Ipaddr.t -> ipaddr
  val of_ipaddr : ipaddr -> Ipaddr.t
end

open Eio.Std

module Make (R : Mirage_random.S) (Mclock : Mirage_clock.MCLOCK) (Time : Mirage_time.S) (W : Ip_wrap) = struct

  let now () = Mtime.of_uint64_ns (Mclock.elapsed_ns ())

  type ipaddr = W.ipaddr

  module Port_map = Map.Make (struct
      type t = int
      let compare (a : int) (b : int) = compare a b
    end)

    
  type t = {
    mutable tcp : Utcp.state ;
    ip : W.t ;
    mutable waiting : (Utcp.flow, (unit, [ `Msg of string ]) result Promise.u) Utcp.FM.t ;
    mutable listeners : (<Eio.Flow.two_way; Eio.Flow.close> -> unit) Port_map.t ;
    sw : Switch.t;
  }
  and flow = t * Utcp.flow

  type Error.t += Refused | Timeout

  let close t flow =
    match Utcp.close t.tcp flow with
    | Ok tcp -> t.tcp <- tcp
    | Error `Msg msg -> Log.err (fun m -> m "error in close: %s" msg)

  let rec read (t, flow) =
    match Utcp.recv t.tcp flow with
    | Ok (tcp, data) ->
      t.tcp <- tcp ;
      if Cstruct.length data = 0 then
        let (promise, resolver) = Promise.create () in
        Utcp.FM.add t.waiting flow resolver;
        Promise.await promise |> ignore; (* ?? *)
        Utcp.FM.remove t.waiting flow;
        read (t, flow)
      else
        (Ok (`Data data))
    | Error `Msg msg ->
      close t flow;
      Log.err (fun m -> m "error while read %s" msg);
      (* TODO better error *)
      Error.v ~__POS__ Refused

  let write (t, flow) buf =
    match Utcp.send t.tcp flow buf with
    | Ok tcp -> 
      t.tcp <- tcp ; 
      (Ok ())
    | Error `Msg msg ->
      close t flow;
      Log.err (fun m -> m "error while write %s" msg);
      (* TODO better error *)
      Error.v ~__POS__ Refused

  type _ Eio.Generic.ty += Flow : flow Eio.Generic.ty

  let chunk_cs = Cstruct.create 10000 

  class flow_obj (flow : flow) =
    object (_ : < Eio.Flow.source ; Eio.Flow.sink ; .. >)
    
      method probe : type a. a Eio.Generic.ty -> a option =
        function Flow -> Some flow | _ -> None

      method copy (src : #Eio.Flow.source) =
        try
          while true do
            let got = Eio.Flow.read src chunk_cs in
            match write flow (Cstruct.sub chunk_cs 0 got) with
            | Ok () -> ()
            | Error _e -> ()
          done
        with End_of_file -> ()

      method read_into buf =
        match read flow with
        | Ok (`Data buffer) ->
            Cstruct.blit buffer 0 buf 0 (Cstruct.length buffer);
            let len = Cstruct.length buffer in
            len
        | Ok `Eof -> raise End_of_file
        | Error _ -> raise End_of_file

      method read_methods = []

      method shutdown (_ : [ `All | `Receive | `Send ]) =
        Printf.printf "SHUTDOWN.\n%!";
        let (t, flow) = flow in
        close t flow

      method close = 
        let (t, flow) = flow in
        close t flow
    end


  let dst (_t, flow) =
    let _, (dst, dst_port) = Utcp.peers flow in
    let dst = W.to_ipaddr dst in
    dst, dst_port

  let write_nodelay flow buf = write flow buf

  let writev_nodelay flow bufs = write flow (Cstruct.concat bufs)

  let output_ip t (src, dst, seg) =
    W.write t.ip ~src:(W.to_ipaddr src) (W.to_ipaddr dst)
      `TCP (fun _ -> 0) [seg]

  let create_connection ?keepalive:_ t (dst, dst_port) =
    let src = W.of_ipaddr (W.src t.ip ~dst) and dst = W.of_ipaddr dst in
    let tcp, id, seg = Utcp.connect ~src ~dst ~dst_port t.tcp (now ()) in
    t.tcp <- tcp;
    match output_ip t seg with
    | Error e ->
      Log.err (fun m -> m "error sending syn: %a" Error.pp (Error.head e));
      Error.v Refused
    | Ok () ->
      let (promise, resolver) = Promise.create () in
      Utcp.FM.add t.waiting id resolver;
      let r = Promise.await promise in
      Utcp.FM.remove t.waiting id;
      match r with
      | Ok () -> Ok (new flow_obj (t, id))
      | Error `Msg msg ->
        Log.err (fun m -> m "error establishing connection: %s" msg);
        (* TODO better error *)
        Error.v Timeout

  let input t ~src ~dst data =
    let src = W.of_ipaddr src and dst = W.of_ipaddr dst in
    let tcp, ev, data = Utcp.handle_buf t.tcp (now ()) ~src ~dst data in
    t.tcp <- tcp;
    let find ?f ctx id r =
      match Utcp.FM.find_opt t.waiting id with
      | Some c -> Promise.resolve c r
      | None -> match f with
        | Some f -> f ()
        | None -> Log.warn (fun m -> m "%a not found in waiting (%s)" Utcp.pp_flow id ctx)
    in
    Option.fold ~none:()
      ~some:(function
          | `Established id ->
            let ctx = "established" in
            let f () =
              let (_, port), _ = Utcp.peers id in
              match Port_map.find_opt port t.listeners with
              | None ->
                Log.warn (fun m -> m "%a not found in waiting or listeners (%s)"
                             Utcp.pp_flow id ctx)
              | Some cb ->
                (* NOTE we start an asynchronous task with the callback *)
                Fiber.fork ~sw:t.sw (fun () -> cb (new flow_obj (t, id)))
            in
            find ~f ctx id (Ok ())
          | `Drop id -> find "drop" id (Error (`Msg "dropped"))
          | `Received id -> find "received" id (Ok ()))
      ev;
    (* TODO do not ignore IP write error *)
    let out_ign t s = 
      ignore (output_ip t s) 
    in
    Fiber.all (Option.to_list data |> List.map (fun s () -> out_ign t s))

  let connect ~sw ~clock ip =
    let tcp = Utcp.empty R.generate in
    let t = { tcp ; ip ; waiting = Hashtbl.create 12 ; listeners = Port_map.empty; sw } in
    Fiber.fork ~sw (fun () ->
        let timer () =
          let tcp, drops, outs = Utcp.timer t.tcp (now ()) in
          t.tcp <- tcp;
          List.iter (fun id ->
              match Utcp.FM.find_opt t.waiting id with
              | None -> Log.warn (fun m -> m "%a not found in waiting"
                                     Utcp.pp_flow id)
              | Some c ->
                Promise.resolve c (Error (`Msg "timer timed out")))
            drops ;
          (* TODO do not ignore IP write error *)
          let out_ign t s = 
            ignore (output_ip t s) 
          in
          Printf.printf "out: %d\n%!" (List.length outs);
          Fiber.all (outs |> List.map (fun s () -> out_ign t s))
        and timeout () =
          Eio.Time.sleep clock 0.1
        in
        let rec go () =
          Fiber.all [ 
            timer ; 
            timeout ;
          ];
          go ()
        in
        go ());
    t

  let listen t ~port ?keepalive:_ callback =
    let tcp = Utcp.start_listen t.tcp port in
    t.tcp <- tcp;
    t.listeners <- Port_map.add port callback t.listeners

  let unlisten t ~port =
    let tcp = Utcp.stop_listen t.tcp port in
    t.tcp <- tcp;
    t.listeners <- Port_map.remove port t.listeners

  let disconnect _t = ()
end

module Make_v4 (R : Mirage_random.S) (Mclock : Mirage_clock.MCLOCK) (Time : Mirage_time.S) (Ip : Tcpip.Ip.S with type ipaddr = Ipaddr.V4.t) = struct
  module W = struct
    include Ip
    let to_ipaddr = function Ipaddr.V4 ip -> ip | _ -> assert false
    let of_ipaddr ip = Ipaddr.V4 ip
  end
  include Make (R) (Mclock) (Time) (W)
end

module Make_v6 (R : Mirage_random.S) (Mclock : Mirage_clock.MCLOCK) (Time : Mirage_time.S) (Ip : Tcpip.Ip.S with type ipaddr = Ipaddr.V6.t) = struct
  module W = struct
    include Ip
    let to_ipaddr = function Ipaddr.V6 ip -> ip | _ -> assert false
    let of_ipaddr ip = Ipaddr.V6 ip
  end
  include Make (R) (Mclock) (Time) (W)
end

module Make_v4v6 (R : Mirage_random.S) (Mclock : Mirage_clock.MCLOCK) (Time : Mirage_time.S) (Ip : Tcpip.Ip.S with type ipaddr = Ipaddr.t) = struct
  module W = struct
    include Ip
    let to_ipaddr = Fun.id
    let of_ipaddr = Fun.id
  end
  include Make (R) (Mclock) (Time) (W)
end
