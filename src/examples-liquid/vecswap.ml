let rec sortRange arr start n =
    let item i = Array.get arr i in
    let swap i j =
     let tmp = item i in
      (Array.set arr i (item j); Array.set arr j tmp)
     in
    let rec vecswap i j n =
      if n = 0 then () else (swap i j; vecswap (i+1) (j+1) (n-1))
    in
    vecswap 0 (n/2) (n/2-1)  
in 
let _ = Random.self_init () in
let vec = Array.make ((Random.int 30) + 5) 0 in
  sortRange vec 0 ((Array.length vec) - 1);;
