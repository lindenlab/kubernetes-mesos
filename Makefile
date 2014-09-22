
# the assumption is that current_dir is something along the lines of:
# 	/home/bob/yourproject/src/github.com/mesosphere/kubernetes-mesos

mkfile_path	:= $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir	:= $(patsubst %/,%,$(dir $(mkfile_path)))
fail		:= ${MAKE} --no-print-directory --quiet -f $(current_dir)/Makefile error

#frmwk_gopath	:= $(shell readlink -f $(current_dir)/../../../..)
frmwk_gopath	:= $(current_dir)

# HACK: this version needs to match the k8s version in Godeps.json
k8s_version	:= 1853c66ddfdfb7d673371e9a2f4be65c066ac81b
k8s_pkg		:= github.com/GoogleCloudPlatform/kubernetes
k8s_repo	:= https://$(k8s_pkg).git
k8s_dir		:= $(frmwk_gopath)/src/$(k8s_pkg)
k8s_git		:= $(k8s_dir)/.git
k8s_gopath	:= $(k8s_dir)/Godeps/_workspace

PROXY_SRC	:= $(k8s_pkg)/cmd/proxy
PROXY_OBJ	:= $(subst $(k8s_pkg)/cmd/,$(frmwk_gopath)/bin/,$(PROXY_SRC))

FRAMEWORK_DIR	:= github.com/mesosphere/kubernetes-mesos
FRAMEWORK_SRC	:= $(FRAMEWORK_DIR)/kubernetes-mesos $(FRAMEWORK_DIR)/kubernetes-executor
FRAMEWORK_OBJ	:= $(subst $(FRAMEWORK_DIR)/,$(frmwk_gopath)/bin/,$(FRAMEWORK_SRC))

OBJS		:= $(PROXY_OBJ) $(FRAMEWORK_OBJ)

DESTDIR		?= /target

.PHONY: all error require-godep framework require-k8s require-frmwk proxy install require-mesos require-protobuf

WITH_DEPS_DIR := $(current_dir)/deps/usr
MESOS_PKG=mesos_0.20.0.293971_amd64.deb
MESOS_URL=http://s3-proxy.lindenlab.com/private-builds-secondlife-com/hg/repo/mesos/rev/293971/arch/Linux/debian_repo/$(MESOS_PKG)

CFLAGS		+= -I$(WITH_DEPS_DIR)/include
CPPFLAGS	+= -I$(WITH_DEPS_DIR)/include
CXXFLAGS	+= -I$(WITH_DEPS_DIR)/include
LDFLAGS		+= -L$(WITH_DEPS_DIR)/lib

CGO_CFLAGS	+= -I$(WITH_DEPS_DIR)/include
CGO_CPPFLAGS	+= -I$(WITH_DEPS_DIR)/include
CGO_CXXFLAGS	+= -I$(WITH_DEPS_DIR)/include
CGO_LDFLAGS	+= -L$(WITH_DEPS_DIR)/lib

WITH_DEPS_CGO_FLAGS :=  \
	  CGO_CFLAGS="$(CGO_CFLAGS)" \
	  CGO_CPPFLAGS="$(CGO_CPPFLAGS)" \
	  CGO_CXXFLAGS="$(CGO_CXXFLAGS)" \
	  CGO_LDFLAGS="$(CGO_LDFLAGS)"

all: $(OBJS)

error:
	echo -E "$@: ${MSG}" >&2
	false

require-godep:
	env GOPATH=$(frmwk_gopath) go get github.com/tools/godep

proxy: $(PROXY_OBJ)

$(PROXY_OBJ): require-k8s
	env GOPATH=$(k8s_gopath):$(frmwk_gopath)$${GOPATH:+:$$GOPATH} go install $(PROXY_SRC)

require-k8s: | $(k8s_git)

$(k8s_git): require-frmwk
	mkdir -p $(k8s_dir)
	test -d $(k8s_git) || git clone $(k8s_repo) $(k8s_dir)
	cd $(k8s_dir) && git checkout $(k8s_version)

require-frmwk:
	test -L src/$(FRAMEWORK_DIR) || ( mkdir -p src/$$(dirname $(FRAMEWORK_DIR)) && ln -sf $(current_dir) src/$$(dirname $(FRAMEWORK_DIR))/$$(basename $(FRAMEWORK_DIR)) )

framework: $(FRAMEWORK_OBJ)

require-mesos:
	test "$(MESOS_URL)" = "" -o -d deps/usr/include/mesos || ( wget http://s3-proxy.lindenlab.com/private-builds-secondlife-com/hg/repo/mesos/rev/293971/arch/Linux/debian_repo/mesos_0.20.0.293971_amd64.deb && dpkg-deb --extract mesos_0.20.0.293971_amd64.deb deps )

require-protobuf:
	test -d deps/usr/include/google/protobuf || ( apt-get download libprotobuf-dev && dpkg-deb --extract libprotobuf-dev_*deb deps )

$(FRAMEWORK_OBJ): require-godep require-mesos require-protobuf
	env PATH=$(frmwk_gopath)/bin:$${PATH:+:$$PATH} \
		GOPATH=$(frmwk_gopath):$(k8s_gopath)$${GOPATH:+:$$GOPATH} \
		$(WITH_DEPS_CGO_FLAGS) \
	 godep get github.com/mesosphere/kubernetes-mesos/$(notdir $@)

install: $(OBJS)
	mkdir -p $(DESTDIR)
	/bin/cp -vpf -t $(DESTDIR) $(FRAMEWORK_OBJ)
	/bin/cp -vpf $(PROXY_OBJ) $(DESTDIR)/kubernetes-proxy

clean:
	rm -f *.deb
	rm -rf pkg src bin deps
