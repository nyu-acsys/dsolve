(* DSOLVE -bare -dontminemlq *)

let f x g = g (x+1) 

let h y = assert (y>2) 

let n = read_int ()

let _ = if n>0 then f n h else ()

