

let create n = 
  (Pa.init n (fun i -> 1), (* rank *) 
   Pa.init n (fun i -> i)) (* parent *)

let rec find_aux p i = 
  let pi = Pa.get p i in
  if pi == i then 
    (p, i)
  else 
    let p', i' = find_aux p pi in 
    let p''    = Pa.set p' i i' in
    (p'', i')
      
let find p i =
  let p',i'  = find_aux p i in 
  (p', i')
  
let union h x y =
  let (r, p)   = h         in
  let (p', x') = find p  x in
  let (p'',y') = find p' y in
  (* HERE *)
  if x' != y' then begin
    let rx' = Pa.get r x' in
    let ry' = Pa.get r y' in
    if rx' > ry' then
      (r, Pa.set p'' y' x')
    else if rx' < ry' then
      (r, Pa.set p'' x' y')
    else
      (Pa.set r rx' (rx' + 1), 
       Pa.set p'' y' x') 
  end else
    (r, p'') 

(*************************************************)

let check h = 
  let (r,p) = h in
  Pa.iteri (fun i v -> assert (v=i || Pa.get r i < Pa.get r v)) p

let tester h = 
  if read_int () > 0 then h else 
    let x  = read_int () in
    let y  = read_int () in
    let h' = union h x y in
    tester h

let n  = read_int ()
let h0 = create n 
let h  = tester n
let _  = check h 

(*
(* Union-Find using Tarjan's algorithm by J.C. Fillaitre *)
type t = { 
  mutable father: Pa.t; (* mutable to allow path compression *)
  c: Pa.t;              (* ranks *)
}

let create n = 
  { c = Pa.create n 0;
    father = Pa.init n (fun i -> i) }
    
let rec find_aux f i = 
  let fi = Pa.get f i in
  if fi == i then 
    f, i
  else 
    let f, r = find_aux f fi in 
    let f = Pa.set f i r in
    f, r
      
let find h x = 
  let f,rx = find_aux h.father x in 
  h.father <- f; rx
  
let union h x y = 
  let rx = find h x in
  let ry = find h y in
  if rx != ry then begin
    let rxc = Pa.get h.c rx in
    let ryc = Pa.get h.c ry in
    if rxc > ryc then
      { h with father = Pa.set h.father ry rx }
    else if rxc < ryc then
      { h with father = Pa.set h.father rx ry }
    else
      { c = Pa.set h.c rx (rxc + 1);
	father = Pa.set h.father ry rx }
  end else
    h
*)