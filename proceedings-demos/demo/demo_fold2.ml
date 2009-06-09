let _ = List.fold_left 
let _ = List.rev

let range i j = 
  let rec f k xs = 
    if k > j
    then List.rev xs 
    else f (k+1) (k::xs) in
  f i []

let arraycat a =
  let n  = Array.length a - 1 in
  let is = range 0 n in
  List.fold_left (fun s i -> s^(Array.get a i)) "" is
