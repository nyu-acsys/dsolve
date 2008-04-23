(* Qualifiers:
   qualif POS(x): 0 <= x    
   qualif LEQ(x)(A:int) : x <= A    
   qualif GEQ(x)(A:int) : A <= x    
   qualif ITV(x): x.0 <= x.1 
 *)

(*********************************************************)

type 'a tree = Leaf of 'a | Node of 'a tree * 'a tree

let rec fold f b t =
  match t with 
  | Leaf x -> f b x
  | Node (t1,t2) -> fold f (fold f b t1) t2

let rec map f t =
  match t with
  | Leaf x -> Leaf (f x)
  | Node (t1,t2) -> Node (map f t1, map f t2)

let rec iter f t =
  match t with
  | Leaf x -> f x
  | Node (t1,t2) -> iter f t1; iter f t2

let rec build f b d = 
  if d <= 0 then (Leaf b, f b) else 
    let (t1,b1) = build f b  (d-1) in
    let (t2,b2) = build f b1 (d-1) in
    ((Node (t1,t2)), b2)

(*********************************************************)

let demo1 d k =
  if k < 0 then () else
    let (t,_) = build ((+) 1) (k+1) d in
    let x = fold (+) k t in
    assert (x >= k)

(*********************************************************)

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

let demo2 d k = 
  if k < 0 then () else 
    let (t,_) = build ((+) 1) k d in
    let t1    = map (fun x -> (x,2*x + 1)) t in
    let (x,y) = fold lub (k,k) t1 in
    iter (fun (a,b) -> assert (k <= a && k <= b)) t1; 
    assert (x <= y)
