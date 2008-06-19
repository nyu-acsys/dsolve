include config/Makefile

QPHOME=external/qp/
CAMLC=ocamlc
CAMLOPT=ocamlopt
CAMLYACC=ocamlyacc
YACCFLAGS=-v
CAMLLEX=ocamllex
CAMLDEP=ocamldep
DEPFLAGS=$(INCLUDES)
COMPFLAGS=$(FLAGS) -g -dtypes -warn-error A $(INCLUDES)
LINKFLAGS=$(FLAGS) -cclib -lstdc++ -cclib -loyices -cclib -lgmp -cclib -lyices \
          -I external/yices/lib/ -I external/ocamlgraph/ -I $(QPHOME)
INCLUDES=-I external/yices/lib/ -I external/ocamlgraph/ -I $(QPHOME) \
         -I utils -I parsing -I typing -I liquid

UTILS=utils/misc.cmo utils/config.cmo \
  utils/clflags.cmo utils/terminfo.cmo utils/ccomp.cmo utils/warnings.cmo \
  utils/tbl.cmo utils/consistbl.cmo utils/heap.cmo utils/bstats.cmo

PARSING=parsing/linenum.cmo parsing/location.cmo parsing/longident.cmo \
  parsing/syntaxerr.cmo parsing/parser.cmo \
  parsing/lexer.cmo parsing/parse.cmo parsing/printast.cmo \
  parsing/pparse.cmo

TYPING=typing/unused_var.cmo typing/ident.cmo typing/path.cmo \
  typing/primitive.cmo typing/types.cmo \
  typing/btype.cmo typing/oprint.cmo \
  typing/subst.cmo typing/predef.cmo \
  typing/datarepr.cmo typing/env.cmo \
  typing/typedtree.cmo typing/ctype.cmo \
  typing/printtyp.cmo typing/includeclass.cmo \
  typing/mtype.cmo typing/includecore.cmo \
  typing/includemod.cmo typing/parmatch.cmo \
  typing/typetexp.cmo typing/stypes.cmo typing/typecore.cmo \
  typing/common.cmo typing/predicate.cmo \
  typing/typedecl.cmo typing/typeclass.cmo \
  typing/qualgen.cmo typing/qualdecl.cmo \
  typing/typemod.cmo typing/qualmod.cmo

LIQUID=liquid/lightenv.cmo \
  liquid/qualifier.cmo liquid/pattern.cmo liquid/frame.cmo \
  liquid/builtins.cmo liquid/wellformed.cmo liquid/message.cmo  \
  liquid/theoremProverSimplify.cmo \
  liquid/theoremProverYices.cmo \
  liquid/theoremProverQprover.cmo \
  liquid/theoremProver.cmo \
  liquid/constraint.cmo liquid/measure.cmo \
  liquid/qualifymod.cmo \
  liquid/qdebug.cmo liquid/normalize.cmo \
  liquid/qdump.cmo liquid/liqerrors.cmo \
	liquid/mlqmod.cmo liquid/liquid.cmo

LIQOBJS=$(UTILS) $(PARSING) $(TYPING) $(LIQUID)

default: liquid.opt

liquid.byte: $(LIQOBJS)
	$(CAMLC) $(LINKFLAGS) -custom -o liquid.byte str.cma unix.cma nums.cma oyices.cma graph.cma libqp.cma $(LIQOBJS)

liquid.opt: $(LIQOBJS:.cmo=.cmx)
	$(CAMLOPT) $(LINKFLAGS) -o liquid.opt str.cmxa unix.cmxa nums.cmxa oyices.cmxa graph.cmxa libqp.cmxa $(LIQOBJS:.cmo=.cmx)

.PHONY: tests
tests:
	./regrtest.py

depend: beforedepend
	(for d in utils parsing typing liquid; \
	 do $(CAMLDEP) $(DEPFLAGS) $$d/*.mli $$d/*.ml; \
	 done) > .depend

clean: partialclean
	(for d in utils parsing typing liquid; \
	 do rm -f $$d/*.cm* $$d/*.o; \
	 done);
	rm -f liquid.byte liquid.opt

distclean: clean
	(for d in ./ utils parsing typing tests liquid; \
	 do rm -f $$d/*.annot $$d/*~ $$d/*.quals $$d/*.pyc $$d/*.dot; \
	 done);
	rm -rf .git external/yices/lib external/yices/bin external/yices/include/*.h

utils/config.ml: utils/config.mlp config/Makefile
	@rm -f utils/config.ml
	sed -e 's|%%LIBDIR%%|$(LIBDIR)|' \
            -e 's|%%BYTERUN%%|$(BINDIR)/ocamlrun|' \
            -e 's|%%CCOMPTYPE%%|cc|' \
            -e 's|%%BYTECC%%|$(BYTECC) $(BYTECCCOMPOPTS) $(SHAREDCCCOMPOPTS)|' \
            -e 's|%%BYTELINK%%|$(BYTECC) $(BYTECCLINKOPTS)|' \
            -e 's|%%NATIVECC%%|$(NATIVECC) $(NATIVECCCOMPOPTS)|' \
            -e 's|%%NATIVELINK%%|$(NATIVECC) $(NATIVECCLINKOPTS)|' \
            -e 's|%%PARTIALLD%%|$(PARTIALLD) $(NATIVECCLINKOPTS)|' \
            -e 's|%%PACKLD%%|$(PARTIALLD) $(NATIVECCLINKOPTS) -o |' \
            -e 's|%%BYTECCLIBS%%|$(BYTECCLIBS)|' \
            -e 's|%%NATIVECCLIBS%%|$(NATIVECCLIBS)|' \
            -e 's|%%RANLIBCMD%%|$(RANLIBCMD)|' \
            -e 's|%%CC_PROFILE%%|$(CC_PROFILE)|' \
            -e 's|%%ARCH%%|$(ARCH)|' \
            -e 's|%%MODEL%%|$(MODEL)|' \
            -e 's|%%SYSTEM%%|$(SYSTEM)|' \
            -e 's|%%EXT_OBJ%%|.o|' \
            -e 's|%%EXT_ASM%%|.s|' \
            -e 's|%%EXT_LIB%%|.a|' \
            -e 's|%%EXT_DLL%%|.so|' \
            -e 's|%%SYSTHREAD_SUPPORT%%|$(SYSTHREAD_SUPPORT)|' \
            utils/config.mlp > utils/config.ml
	@chmod -w utils/config.ml

partialclean::
	rm -f utils/config.ml

beforedepend:: utils/config.ml

parsing/parser.mli parsing/parser.ml: parsing/parser.mly
	$(CAMLYACC) $(YACCFLAGS) parsing/parser.mly

partialclean::
	rm -f parsing/parser.mli parsing/parser.ml parsing/parser.output

beforedepend:: parsing/parser.mli parsing/parser.ml

# The lexer

parsing/lexer.ml: parsing/lexer.mll
	$(CAMLLEX) parsing/lexer.mll

partialclean::
	rm -f parsing/lexer.ml

beforedepend:: parsing/lexer.ml

# The auxiliary lexer for counting line numbers

parsing/linenum.ml: parsing/linenum.mll
	$(CAMLLEX) parsing/linenum.mll

partialclean::
	rm -f parsing/linenum.ml

beforedepend:: parsing/linenum.ml

.SUFFIXES: .ml .mli .cmo .cmi .cmx

.ml.cmo:
	$(CAMLC) $(COMPFLAGS) -c $<

.mli.cmi:
	$(CAMLC) $(COMPFLAGS) -c $<

.ml.cmx:
	$(CAMLOPT) $(COMPFLAGS) -c $<

yiceslib:
	mkdir -p external/yices/include/build; cd external/yices/include/build; $(MAKE) -f ../Makefile;

graphlib:
	cd external/ocamlgraph; ./configure; $(MAKE) all;

qplib:
	cd $(QPHOME); $(MAKE) qp.opt; $(MAKE) all

libs: yiceslib graphlib qplib

world: liquid.byte liquid.opt

include .depend
