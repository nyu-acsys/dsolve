
let rec generate m f b = 
  if m <= 0 then [] else (b::(generate (m-1) f (f b)))

let demo1 m k =
  if (k < 0) then () else
    let xs = generate m (fun x -> x + 1) (k+1) in
    let x  = List.fold_left (fun a b -> a + b) k xs in
    assert (x >= k)

let demo2 m = 
  let xs = generate m (fun x -> 2 * x) (-1) in
  let x  = List.fold_left (+) 0 xs in
  assert (x <= 0)

let demo3 m = 
  let xs  = generate m (fun x -> x + 1) 0 in
  let xs' = List.map (fun x -> 0 - x) xs in 
  let x   = List.fold_left (+) 0 xs' in
  assert (x <= 0)

let demo4 m = 
  let xs = generate m (fun x -> 2 * x) (-1) in
  let xs'= List.map (fun x -> 0 - x) xs in 
  let x  = List.fold_left (+) 0 xs' in
  assert (x >= 0)
