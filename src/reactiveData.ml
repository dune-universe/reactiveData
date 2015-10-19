(* ReactiveData
 * https://github.com/hhugo/reactiveData
 * Copyright (C) 2014 Hugo Heuzard
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

module type DATA = sig
  type 'a data
  type 'a patch
  val merge : 'a patch -> 'a data -> 'a data
  val map_patch : ('a -> 'b) -> 'a patch -> 'b patch
  val map_data : ('a -> 'b) -> 'a data -> 'b data
  val empty : 'a data
  val equal : ('a -> 'a -> bool) -> 'a data -> 'a data -> bool
  val diff : 'a data -> 'a data -> eq:('a -> 'a -> bool) -> 'a patch
end
module type S = sig
  type 'a data
  type 'a patch
  type 'a msg = Patch of 'a patch | Set of 'a data
  type 'a handle
  type 'a t
  val empty : 'a t
  val make : ?eq:('a -> 'a -> bool) -> 'a data -> 'a t * 'a handle
  val make_from :
    ?eq:('a -> 'a -> bool) -> 'a data -> 'a msg React.E.t -> 'a t
  val make_from_s :
    ?eq:('a -> 'a -> bool) -> 'a data React.S.t -> 'a t
  val const : 'a data -> 'a t
  val patch : 'a handle -> 'a patch -> unit
  val set   : 'a handle -> 'a data -> unit
  val map_msg : ('a -> 'b) -> 'a msg -> 'b msg
  val map : ?eq:('b -> 'b -> bool) -> ('a -> 'b) -> 'a t -> 'b t
  val value : 'a t -> 'a data
  val fold :
    ?eq:('a -> 'a -> bool) ->
    ('a -> 'b msg -> 'a) ->
    'b t -> 'a -> 'a React.signal
  val value_s : 'a t -> 'a data React.S.t
  val event : 'a t -> 'a msg React.E.t
end

module Make(D : DATA) :
  S with type 'a data = 'a D.data
     and type 'a patch = 'a D.patch =
struct

  type 'a data = 'a D.data
  type 'a patch = 'a D.patch
  let merge = D.merge
  let map_patch = D.map_patch
  let map_data = D.map_data

  type 'a msg =
    | Patch of 'a patch
    | Set of 'a data

  type 'a t =
    | Const of 'a data
    | React of ('a -> 'a -> bool) * ('a data * 'a msg) React.S.t

  type 'a handle = (?step:React.step -> 'a msg -> unit)

  let empty = Const D.empty

  let make_from ?(eq = (=)) l event =
    let f (l, e) = function
      | Set l' ->
        l', Patch (D.diff l l' ~eq)
      | Patch p as p' ->
        merge p l, p'
    in
    React (eq, React.S.fold f (l, Set l) event)

  let make ?eq l =
    let event, send = React.E.create () in
    make_from ?eq l event, send

  let const x = Const x

  let map_msg (f : 'a -> 'b) : 'a msg -> 'b msg = function
    | Set l -> Set (map_data f l)
    | Patch p -> Patch (map_patch f p)

  let value = function
    | Const c -> c
    | React (_, s) -> fst (React.S.value s)

  let map ?(eq = (=)) f s =
    match s with
    | Const x ->
      Const (map_data f x)
    | React (_, s) ->
      let f (l, m) = map_data f l, map_msg f m in
      React (eq, React.S.map f s)

  let event s = match s with
    | Const _ ->
      React.E.never
    | React (_, e) ->
      let f (_, p) _ = p in
      React.S.diff f e

  let patch (h : _ handle) p = h (Patch p)

  let set (h : _ handle) l = h (Set l)

  (* TODO: use ppx_deriving? *)

  let fst_nth_eq eq x y =
    match x, y with
    | `Fst x, `Fst y
    | `Nth x, `Nth y ->
      eq x y
    | _, _ ->
      false

  let fold ?(eq = (=)) f s acc =
    match s with
    | Const c ->
      React.S.const (f acc (Set c))
    | React (eq', s) ->
      let unwrap = function `Fst x -> x | `Nth x -> x in
      let l0 = fst (React.S.value s) in
      let acc = f acc (Set l0) in
      let s =
        let d = let f v' v = v', v in React.S.diff f s
        and f acc ((l', m'), (l, _)) =
          match acc with
          | `Fst acc when (D.equal eq' l l0) ->
            `Nth (f acc m')
          | `Fst acc ->
            let acc = f acc (Set l') in
            `Nth (f acc m')
          | `Nth acc ->
            `Nth (f acc m')
        and eq = fst_nth_eq eq in
        React.S.fold ~eq f (`Fst acc) d
      in
      React.S.map ~eq unwrap s

  let value_s = function
    | Const c -> React.S.const c
    | React (_, s) -> React.S.Pair.fst s

  let make_from_s ?(eq = (=)) signal =
    let event =
      let f l' l = Patch (D.diff l l' ~eq) in
      React.S.diff f signal
    and v = React.S.value signal in
    make_from ~eq v event

end

let rec list_rev ?(acc = []) = function
    | h :: t ->
      let acc = h :: acc in
      list_rev ~acc t
    | [] ->
      acc

module DiffList : sig
  val fold :
    ?eq    : ('a -> 'a -> bool) ->
    'a list -> 'a list ->
    acc    : 'acc ->
    remove : ('acc -> int -> 'acc) ->
    add    : ('acc -> int -> 'a -> 'acc) ->
    'acc
end = struct

  let mem l =
    let h = Hashtbl.create 1024 in
    List.iter (fun x -> Hashtbl.add h x ()) l;
    Hashtbl.mem h

  let lcs ?(eq = (=)) lx ly =
    let h = Hashtbl.create 1024
    and memx = mem lx
    and memy = mem ly in
    let rec lcs lx ox ly oy ~acc ~left =
      try Hashtbl.find h (lx, ly) with
      | Not_found ->
        let result =
          match lx, ly with
          | [], _
          | _, [] ->
            acc
          | x :: lx, y :: ly when eq x y ->
            let acc = (ox, oy) :: acc in
            lcs lx (ox + 1) ly (oy + 1) ~acc ~left
          | x :: lx, ly when not (memy x) ->
            lcs lx (ox + 1) ly oy ~acc ~left
          | lx, y :: ly when not (memx y) ->
            lcs lx ox ly (oy + 1) ~acc ~left
          | _ :: lx, _ when left ->
            lcs lx (ox + 1) ly oy ~acc ~left:false
          | _, _ :: ly ->
            lcs lx ox ly (oy + 1) ~acc ~left:true
        in
        Hashtbl.add h (lx, ly) result;
        result
    and acc = [] and left = true in
    lcs lx 0 ly 0 ~acc ~left |> list_rev

  let rec fold_removed ?(i = 0) ?(offset = 0) l ~max ~f ~acc =
    let rec fold j ~max ~offset ~acc =
      if j < max then begin
        let acc = f acc (j - offset) in
        let offset = offset + 1 in
        fold (j + 1) ~max ~offset ~acc
      end
      else
        offset, acc
    in
    match l with
    | (n, _) :: l ->
      assert (n < max);
      let offset, acc = fold i ~max:n ~offset ~acc
      and i = n + 1 in
      fold_removed ~i ~offset l ~max ~f ~acc
    | [] ->
      let _, acc = fold i ~max ~offset ~acc in acc

  let rec fold_added ?(i = 0) l a ~f ~acc =
    let rec g u acc j =
      if j < u then
        let acc = f acc j a.(j) in
        g u acc (j + 1)
      else
        acc
    in
    match l with
    | (_, n) :: l ->
      let acc = g n acc i
      and i = n + 1 in
      fold_added ~i l a ~f ~acc
    | [] ->
      g (Array.length a) acc i

  let fold ?eq x y ~acc ~remove ~add =
    let l = lcs ?eq x y
    and max = List.length x in
    let acc = fold_removed l ~max ~f:remove ~acc in
    fold_added l (Array.of_list y) ~f:add ~acc

end

module DataList = struct
  type 'a data = 'a list
  type 'a p =
    | I of int * 'a
    | R of int
    | U of int * 'a
    | X of int * int
  type 'a patch = 'a p list
  let empty = []
  let map_data = List.map
  let map_patch f = function
    | I (i,x) -> I (i, f x)
    | R i -> R i
    | X (i,j) -> X (i,j)
    | U (i,x) -> U (i,f x)
  let map_patch f = List.map (map_patch f)

  let merge_p op l =
    match op with
    | I (i',x) ->
      let i = if i' < 0 then List.length l + 1 + i' else i' in
      let rec aux acc n l = match n,l with
        | 0,l -> List.rev_append acc (x::l)
        | _,[] -> failwith "ReactiveData.Rlist.merge"
        | n,x::xs -> aux (x::acc) (pred n) xs
      in aux [] i l
    | R i' ->
      let i = if i' < 0 then List.length l + i' else i' in
      let rec aux acc n l = match n,l with
        | 0,x::l -> List.rev_append acc l
        | _,[] -> failwith "ReactiveData.Rlist.merge"
        | n,x::xs -> aux (x::acc) (pred n) xs
      in aux [] i l
    | U (i',x) ->
      let i = if i' < 0 then List.length l + i' else i' in
      let a = Array.of_list l in
      a.(i) <- x;
      Array.to_list a
    | X (i',offset) ->
      let a = Array.of_list l in
      let len = Array.length a in
      let i = if i' < 0 then len + i' else i' in
      let v = a.(i) in
      if offset > 0
      then begin
        if (i + offset >= len) then failwith "ReactiveData.Rlist.merge";
        for j = i to i + offset - 1 do
          a.(j) <- a.(j + 1)
        done;
        a.(i+offset) <- v
      end
      else begin
        if (i + offset < 0) then failwith "ReactiveData.Rlist.merge";
        for j = i downto i + offset + 1 do
          a.(j) <- a.(j - 1)
        done;
        a.(i+offset) <- v
      end;
      Array.to_list a

  (* accumulates into acc i unmodified elements from l *)
  let rec linear_merge_fwd i l ~acc =
    assert (i >= 0);
    if i > 0 then
      match l with
      | h :: l ->
        let acc = h :: acc in
        linear_merge_fwd (i - 1) l ~acc
      | [] ->
        invalid_arg "invalid index"
    else
      l, acc

  let rec linear_merge i0 p l ~acc =
    let l, acc =
      match p with
      | (I (i, _) | R i | U (i, _)) :: _ when i > i0 ->
        linear_merge_fwd (i - i0) l ~acc
      | _ ->
        l, acc
    in
    match p, l with
    | I (i, x) :: p, _ ->
      linear_merge i p (x :: l) ~acc
    | R i :: p, _ :: l ->
      linear_merge i p l ~acc
    | R _ :: _, [] ->
      invalid_arg "merge: invalid index"
    | U (i, x) :: p, _ :: l ->
      linear_merge i p (x :: l) ~acc
    | U (_, _) :: _, [] ->
      invalid_arg "merge: invalid index"
    | [], l ->
      List.rev_append acc l
    | X (_, _) :: _, _ ->
      failwith "linear_merge: X not supported"

  let rec linear_mergeable p ~n =
    assert (n >= 0);
    match p with
    | (I (i, _) | R i | U (i, _)) :: p when i >= n ->
      (* negative i's ruled out (among others) *)
      linear_mergeable p ~n:i
    | _ :: _ ->
      false
    | [] ->
      true

  let merge p l =
    if linear_mergeable p ~n:0 then
      linear_merge 0 p l ~acc:[]
    else
      List.fold_left (fun l x -> merge_p x l) l p

  let rec equal f l1 l2 =
    match l1, l2 with
    | x1 :: l1, x2 :: l2 when f x1 x2 ->
      equal f l1 l2
    | [], [] ->
      true
    | _ :: _ , _ :: _
    | _ :: _ , []
    | []     , _ :: _ ->
      false

  let diff x y ~eq =
    let add acc i v = I (i, v) :: acc
    and remove acc i = R i :: acc
    and acc = [] in
    DiffList.fold ~eq x y ~acc ~add ~remove |> list_rev

end

module RList = struct
  include Make (DataList)
  module D = DataList
  type 'a p = 'a D.p =
    | I of int * 'a
    | R of int
    | U of int * 'a
    | X of int * int

  let nil = empty
  let append x s = patch s [D.I (-1,x)]
  let cons x s = patch s [D.I (0,x)]
  let insert x i s = patch s [D.I (i,x)]
  let update x i s = patch s [D.U (i,x)]
  let move i j s = patch s [D.X (i,j)]
  let remove i s = patch s [D.R i]

  let singleton x = const [x]

  let singleton_s s =
    let first = ref true in
    let e,send = React.E.create () in
    let result = make_from [] e in
    let _ = React.S.map (fun x ->
        if !first
        then begin
          first:=false;
          send (Patch [I(0,x)])
        end
        else send (Patch [U(0,x)])) s in
    result

  let concat : 'a t -> 'a t -> 'a t = fun x y ->
    let v1 = value x
    and v2 = value y in
    let size1 = ref 0
    and size2 = ref 0 in
    let size_with_patch sizex : 'a D.p -> unit = function
      | (D.I _) -> incr sizex
      | (D.R _) -> decr sizex
      | (D.X _ | D.U _) -> () in
    let size_with_set sizex l = sizex:=List.length l in

    size_with_set size1 v1;
    size_with_set size2 v2;

    let update_patch1 = List.map (fun p ->
        let m = match p with
          | D.I (pos,x) ->
            let i = if pos < 0 then pos - !size2 else pos in
            D.I (i, x)
          | D.R pos     -> D.R  (if pos < 0 then pos - !size2 else pos)
          | D.U (pos,x) -> D.U ((if pos < 0 then pos - !size2 else pos), x)
          | D.X (i,j) ->   D.X ((if i < 0 then i - !size2 else i),j)
        in
        size_with_patch size1 m;
        m) in
    let update_patch2 = List.map (fun p ->
        let m = match p with
          | D.I (pos,x) -> D.I ((if pos < 0 then pos else !size1 + pos), x)
          | D.R pos     -> D.R  (if pos < 0 then pos else !size1 + pos)
          | D.U (pos,x) -> D.U ((if pos < 0 then pos else !size1 + pos), x)
          | D.X (i,j) ->   D.X ((if i < 0 then i else !size1 + i),j)
        in
        size_with_patch size2 m;
        m) in
    let tuple_ev =
      React.E.merge (fun acc x ->
          match acc,x with
          | (None,p2),`E1 x -> Some x,p2
          | (p1,None),`E2 x -> p1, Some x
          | _ -> assert false)
        (None,None)
        [React.E.map (fun e -> `E1 e) (event x);
         React.E.map (fun e -> `E2 e) (event y)] in
    let merged_ev = React.E.map (fun p ->
        match p with
        | Some (Set p1), Some (Set p2) ->
          size_with_set size1 p1;
          size_with_set size2 p2;
          Set (p1 @ p2)
        | Some (Set p1), None ->
          size_with_set size1 p1;
          Set (p1 @ value y)
        | None, Some (Set p2) ->
          size_with_set size2 p2;
          Set (value x @ p2 )
        | Some (Patch p1), Some (Patch p2) ->
          let p1 = update_patch1 p1 in
          let p2 = update_patch2 p2 in
          Patch (p1 @ p2)
        | Some (Patch p1), None -> Patch (update_patch1 p1)
        | None, Some (Patch p2) -> Patch (update_patch2 p2)
        | Some (Patch p1), Some (Set s2) ->
          let s1 = value x in
          size_with_set size1 s1;
          size_with_set size2 s2;
          Set(s1 @ s2)
        | Some (Set s1), Some (Patch p2) ->
          size_with_set size1 s1;
          let s2 = value y in
          size_with_set size2 s2;
          Set(s1 @ s2)
        | None,None -> assert false
      ) tuple_ev in
    make_from (v1 @ v2) merged_ev

  let inverse : 'a . 'a p -> 'a p = function
    | I (i,x) -> I(-i-1, x)
    | U (i,x) -> U(-i-1, x)
    | R i -> R (-i-1)
    | X (i,j) -> X (-i-1,-j)

  let rev t =
    let e = React.E.map (function
        | Set l -> Set (List.rev l)
        | Patch p -> Patch (List.map inverse p))  (event t)
    in
    make_from (List.rev (value t)) e

  let sort eq t = `Not_implemented
    (* let e = React.E.map (function *)
    (*     | Set l -> Set (List.sort eq l) *)
    (*     | Patch p -> Patch p)  (event t) *)
    (* in *)
    (* make_from (List.sort eq (value t)) e *)

  let filter f t = `Not_implemented

end

module RMap(M : Map.S) = struct

  module Data = struct

    type 'a data = 'a M.t

    type 'a p = [`Add of (M.key * 'a) | `Del of M.key]

    type 'a patch = 'a p list

    let merge_p p s =
      match p with
      | `Add (k,a) -> M.add k a s
      | `Del k -> M.remove k s

    let merge p acc = List.fold_left (fun acc p -> merge_p p acc) acc p

    let map_p f = function
      | `Add (k,a) -> `Add (k,f a)
      | `Del k -> `Del k

    let map_patch f = List.map (map_p f)

    let map_data f d = M.map f d

    let empty = M.empty

    let equal f = M.equal f

    let diff x y ~eq =
      let m =
        let g key v w =
          match v, w with
          | Some v, Some w when eq v w ->
            None
          | Some _, Some w ->
            Some (`U w)
          | Some _, None ->
            Some `D
          | None, Some v ->
            Some (`A v)
          | None, None ->
            None
        in
        M.merge g x y
      and g key x acc =
        match x with
        | `U v ->
          `Del key :: `Add (key, v) :: acc
        | `D ->
          `Del key :: acc
        | `A v ->
          `Add (key, v) :: acc
      and acc = [] in
      M.fold g m acc |> List.rev

  end

  include Make(Data)

end
