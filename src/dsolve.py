#!/usr/bin/python

import sys
import os
import os.path

gen   = "./liquid.opt -no-anormal -dqualifs -lqualifs"
solve = "./liquid.opt -dframes"
flags = []
tname = "/tmp/liq"

def cat_files(files,outfile):
  os.system("rm -f %s" % outfile)
  for f in files: os.system("cat %s 1>> %s 2> /dev/null" % (f,outfile))

def read_lines(name):
  f = open(name)
  lines = f.readlines()
  f.close()
  return lines

def write_line(name,line):
  f = open(name,"w")
  f.write(line)
  f.close()

def logged_sys_call(s):
  print "exec: " + s
  os.system(s)

def gen_quals(src,bare):
  (fname,qname,hname) = (src+".ml", src + ".quals", src + ".hquals")
  if bare:
    os.system("touch %s" % (qname))
  else:
    logged_sys_call("%s %s 1> /dev/null 2> %s" % (gen, fname, qname))
  cat_files([hname,qname],tname+".quals")
  cat_files([tname+".quals",fname],tname+".ml")

def solve_quals(src,flags):
  logged_sys_call("%s %s %s.ml" % (solve, " ".join(flags),src))

def fix_annots(src,dst):
  quallines  = read_lines(src+".quals")
  lineoffset = len(quallines)
  charoffset = len("".join(quallines))
  outlines  = []
  for line in read_lines(src+".annot"): 
      fields = line.split(" ")
      if fields[0] == '"%s.ml"' % src:
          for i in [0,4]: fields[i] = '"' + dst + ".ml" + '"'
          for i in [1,5]: fields[i] = str(int(fields[i]) - lineoffset)
          for j in [2,3,6]: fields[j] = str(int(fields[j]) - charoffset)
          fields[7] = str(int(fields[7]) - charoffset) + "\n"
      outlines.append(" ".join(fields))
  write_line(dst + ".annot", "".join(outlines))

# main
bname = sys.argv[len(sys.argv) - 1][:-3]
bare = (sys.argv[1] == "-bare")
if bare: flags += sys.argv[2:-1]
else: flags += sys.argv[1:-1]
os.system("rm -f %s.quals; rm -f %s.annot" % (bname, bname))	
gen_quals(bname,bare)
solve_quals(tname,flags)
fix_annots(tname,bname)
