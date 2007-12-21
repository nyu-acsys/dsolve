qualif Geq_x(v) : v >= x
qualif Geq_y(v) : v >= y
qualif NonNegative(v) : v >= 0
qualif Leq_n(v) : v <= n
qualif Neq_n(v) : v != n
qualif Leq_a_length(v) : v <= Array.length a
qualif Neq_a_length(v) : v != Array.length a

let max x y =
  if x > y then x else y

let rec sum k =
  if k < 0 then 0 else
    let s = sum (k-1) in
      s + k 

let foldn n b f =
  let rec loop i c =
    if i < n then loop (i+1) (f i c) else c in
    loop 0 b

let arraymax a =
  let am l m = max (Array.get a l) m in
    foldn (Array.length a) 0 am

let arraytest a =
  let vec = Array.make (Random.int 40)  0 in
    arraymax vec
