let rec sum x = if x <= 0 then 0 else x + sum (x - 1)
and main () = assert (100 <= sum 100)
