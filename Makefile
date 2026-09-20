#@BEGIN-DIR-DEFAULT-RULES@
all:
	@if [ -d "src" -a -f "src/Makefile" ]; then (cd src && $(MAKE) all); fi
	@if [ -d "c_src" -a -f "c_src/Makefile" ]; then (cd c_src && $(MAKE) all); fi
	@if [ -d "test" -a -f "test/Makefile" ]; then (cd test && $(MAKE) all); fi

clean:
	@if [ -d "src" -a -f "src/Makefile" ]; then (cd src && $(MAKE) clean); fi
	@if [ -d "c_src" -a -f "c_src/Makefile" ]; then (cd c_src && $(MAKE) clean); fi
	@if [ -d "test" -a -f "test/Makefile" ]; then (cd test && $(MAKE) clean); fi
#@END-DIR-DEFAULT-RULES@

PA=$(wildcard ../*/ebin)
CONFIG=$(if $(wildcard local.config),local,sys)

# start the gui:  make run [CONFIG=local|sys]
run: all
	erl -pa $(PA) -config $(CONFIG) -s gillespie gui

# start a shell with gillespie loaded
shell: all
	erl -pa $(PA) -config $(CONFIG) -s gillespie start
