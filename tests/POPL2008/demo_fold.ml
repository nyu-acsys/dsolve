(*
 * qualif POS(x): x >= 0 
 * qualif NEG(x): x <= 0 
 * qualif LEQ(x)(A:int) : x <= ~A
 * qualif GEQ(x)(A:int) : ~A <= x    
 * qualif ITV(x): x.1 <= x.2 
 *)

(*********************************************************************)

let rec generate m f b = 
  if m <= 0 then [] else (b::(generate m f (f b)))

let demo1 m = 
  let xs = generate m (fun x -> x + 1) 0 in
  let x  = List.fold_left (+) 0 xs in
  assert (x >= 0)

let demo2 m = 
  let xs = generate m (fun x -> 2 * x) (-1) in
  let x  = List.fold_left (+) 0 xs in
  assert (x <= 0)

let demo3 m = 
  let xs  = generate m (fun x -> x + 1) 0 in
  let xs' = List.map (fun x -> -x) xs in 
  let x   = List.fold_left (+) 0 xs in
  assert (x <= 0)

let demo4 m = 
  let xs = generate m (fun x -> 2 * x) (-1) in
  let xs'= List.map (fun x -> -x) xs in 
  let x  = List.fold_left (+) 0 xs in
  assert (x >= 0)

(*********************************************************************)

let mmin (x:int) y = 
  if x <= y then x else y

let mmax (x:int) y = 
  if x <= y then y else x

let lub (p: int*int) (p':int*int) = 
  let (x,y) = p in
  let (x',y') = p' in
  let x'' = mmin x x' in
  let y'' = mmax y y' in
  (x'',y'')

let demo5 m = 
  let xs = generate m (fun p -> let (a,b) = p in (2*a - 10, 3*b + 20)) (1,1) in
  let (x,y) = List.fold_left lub (1,1) xs in
  assert (x <= y)

(*********************************************************************)

let rec read_pos_int () = 
  let x = read_int () in
  if x >= 0 then x else read_pos_int ()

let read_pair_wf () = 
  let x = read_int () in
  let y = read_pos_int () in
  (x,x+y)

let rec mklist n = 
  if n < 0 then [] else 
    let p = read_pair_wf () in
    let xs = mklist (n-1) in
    p::xs

let demo6 m =  
  let ys = mklist m in
  let b = read_pair_wf () in
  let (x,y) = List.fold_left lub b ys in
  assert (x <= y) 

(*********************************************************************)
