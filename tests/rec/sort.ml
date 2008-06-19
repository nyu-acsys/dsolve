(**************************************************************************************)
(******************************* Quick Sort *******************************************)
(**************************************************************************************)

type ('a,'b) boolean = 
  | True of 'a
  | False of 'b

let rec partition f xs = 
  match xs with
  | [] -> ([], [])
  | x::xs' -> 
      let (ts,fs) = partition f xs' in
      (match f x with 
       | True x' ->  (x'::ts,fs)
       | False x' -> (ts,x'::fs))

let rec append k xs ys = 
  match xs with
  | []     -> ys
  | x::xs' -> x::(append k xs' ys)

let rec quicksort = function 
  | [] -> [] 
  | x::xs ->
      let (ls,rs) = partition (fun y -> if y < x then True y else False y) xs in
      let (ls',rs') = (quicksort ls, quicksort rs) in
      append x ls' (x::rs')
 
(**************************************************************************************)
(************************ Faster Quick Sort *******************************************)
(**************************************************************************************)

let reverse =
  let rec rev k rs = function 
    | []    -> k::rs
    | y::ys -> rev y (k::rs) ys in
  function 
    | [] -> [] 
    | x::xs -> rev x [] xs 

let rec rev_append k xs ys =
  match xs with
  | [] -> ys
  | x::xs' -> rev_append x xs' (x::ys)

let rec quicksort2 = function
  | [] -> []
  | x::xs ->
      let (ls,rs) = partition (fun y -> if y < x then True y else False y) xs in
      let (ls',rs') = (quicksort2 ls, quicksort2 rs) in
      rev_append x (reverse ls') (x::rs')

(**************************************************************************************)
(******************************* Merge Sort *******************************************)
(**************************************************************************************)

let rec halve = function 
  | []   -> [], []
  | [x]  -> [x], []
  | x::xs ->
      let (ys, zs) = halve xs in
      (x::zs, ys)

let rec merge xs ys = 
  match (xs,ys) with
  | (_,[]) -> 
      xs
  | ([],_) -> 
      ys
  | (x::xs',y::ys') ->
      if x < y 
      then x::(merge xs' (y::ys')) 
      else y::(merge (x::xs') ys')

let rec mergesort = function 
  | []  -> []
  | [x] -> [x]
  | xs  -> 
      let (ys,zs) = halve xs in
      merge (mergesort ys) (mergesort zs)

(**************************************************************************************)
(******************************* DML Merge Sort ***************************************)
(**************************************************************************************)

let rec initlist = function
  | [] -> []
  | [x] -> [[x]]
  | x1::x2::xs -> (* bug in DML version! *)
      let y = if x1 < x2 then [x1;x2] else [x2;x1] in
      let ys = initlist xs in
      y::ys

let rec merge xs ys = 
  match xs, ys with
  | [],_  -> ys
  | _ ,[] -> xs
  | (x::xs'),(y::ys') ->
      if x < y 
      then x::(merge xs' (y::ys')) 
      else y::(merge (x::xs') ys')

let rec merge2 xss = 
  match xss with 
  | [] -> []
  | [xs] -> [xs]
  | xs1::xs2::xss' -> (merge xs1 xs2)::(merge2 xss')

let rec mergeall xss = 
  match xss with 
  | []  -> [] 
  | [xs] -> xs
  | _  -> mergeall (merge2 xss)

let mergesort2 xs =
  mergeall (initlist xs)

(**************************************************************************************)
(******************************* Insertion Sort ***************************************)
(**************************************************************************************)

let rec insert x = function
  | [] -> [x]
  | y::ys -> 
      if x <= y 
      then (x::y::ys)
      else (y::(insert x ys))

let rec insertsort = function
  | [] -> []
  | x::xs -> insert x (insertsort xs)
