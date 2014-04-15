MAINTAINERCLEANFILES	= Makefile.in

TARGET			= fence_ipal

SYMTARGET               = ipal

SRC			= $(TARGET).py

EXTRA_DIST		= $(SRC)

sbin_SCRIPTS		= $(TARGET)
bin_SCRIPTS		= $(SYMTARGET)

include $(top_srcdir)/make/fencebuild.mk
include $(top_srcdir)/make/fenceman.mk

clean-local: clean-man
	rm -f $(TARGET) $(SYMTARGET)
