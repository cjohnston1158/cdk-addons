BUILD=build
KUBE_ARCH=amd64
# NB: change this to ./stable-1.xx.txt on relevant cdk-addons release-1.xx branches
KUBE_VERSION=$(shell curl -L https://dl.k8s.io/release/latest.txt)
KUBE_ERSION=$(subst v,,${KUBE_VERSION})
PWD=$(shell pwd)
RELEASE_BRANCH=release-$(basename ${KUBE_ERSION})
LOCAL_BRANCH=$(strip $(shell git symbolic-ref HEAD 2>/dev/null | sed -e 's|^refs/heads/||'))
REMOTE_BRANCH=$(strip $(shell git branch --list -r '*/'${RELEASE_BRANCH}))

# cdk-addons release branch for comparing images. By default, this should be
# set to the previous stable release-1.xx branch.
PREV_RELEASE=release-1.23

## Pin some addons to known-good versions
# NB: If we lock images to commits/versions, this could affect the image
# version matching in ./get-addon-templates. Be careful here, and verify
# any images we need based on commit are matched/substituted correctly.
CEPH_CSI_COMMIT=00f88e58a0b08be3d7ea009a0cfde8dca23021bf  # v3.5.1
COREDNS_COMMIT=cb075b0a3810ccc0cb83339ddbce4b094c8f499b  # v1.9.0
OPENSTACK_PROVIDER_COMMIT=1b5899e9f4c7c35e98e0be94732a88452b36cd15  # v1.23.1
KUBE_DASHBOARD_COMMIT=52001304228c58430485674d21458527c8e6d86a  # v2.5.1
KUBE_STATE_METRICS_COMMIT=ef8bede4064f04472a8c2fe8c281e6bf97de4329  # v2.4.2

default: prep
	wget -O ${BUILD}/kubectl https://storage.googleapis.com/kubernetes-release/release/${KUBE_VERSION}/bin/linux/${KUBE_ARCH}/kubectl
	chmod +x ${BUILD}/kubectl
	sed 's/KUBE_VERSION/${KUBE_ERSION}/g' cdk-addons.yaml > ${BUILD}/snapcraft.yaml
	sed -i "s/KUBE_ARCH/${KUBE_ARCH}/g" ${BUILD}/snapcraft.yaml
# NB: do not call cleanbuild as jenkins cannot run the confined lxd snap from /var/lib/jenkins.
# Generic build is safe here as the snap doesnt build anything, hence cant be polluted from the host.
	cd ${BUILD} && snapcraft
	mv build/*.snap .

clean:
	@rm -rf ${BUILD} ${PREV_RELEASE} templates

docker: clean
	docker build -t cdk-addons-builder .
	docker run --rm -v ${PWD}:/root/snap -w /root/snap -e SNAPCRAFT_SETUP_CORE=1 cdk-addons-builder make KUBE_VERSION=${KUBE_VERSION} KUBE_ARCH=${KUBE_ARCH}

prep: clean
	cp -r cdk-addons ${BUILD}
	KUBE_VERSION=${KUBE_VERSION} KUBE_DASHBOARD_COMMIT=${KUBE_DASHBOARD_COMMIT} CEPH_CSI_COMMIT=${CEPH_CSI_COMMIT} COREDNS_COMMIT=${COREDNS_COMMIT} OPENSTACK_PROVIDER_COMMIT=${OPENSTACK_PROVIDER_COMMIT} KUBE_STATE_METRICS_COMMIT=${KUBE_STATE_METRICS_COMMIT} ./get-addon-templates
	mv templates ${BUILD}

upstream-images: prep
	$(eval RAW_IMAGES := "$(shell grep -rhoE 'image:.*' ./${BUILD}/templates | sort -u)")
# NB: sed cleans up image prefix, quotes, and matches '{{ registry|default('k8s.gcr.io') }}/foo-{{ bar }}:latest', replacing the first {{..}} with the specified default registry
	$(eval UPSTREAM_IMAGES := $(shell echo ${RAW_IMAGES} | sed -E -e "s/image: //g" -e "s/\{\{ registry\|default\(([^}]*)\) }}/\1/g" -e "s/['\"]//g"))
	@echo "${KUBE_VERSION}-upstream: ${UPSTREAM_IMAGES}"

compare-prep:
	git clone --branch ${PREV_RELEASE} --single-branch --depth 1 https://github.com/charmed-kubernetes/cdk-addons.git ${PREV_RELEASE}
	$(MAKE) -C ${PREV_RELEASE} prep

branch-matches-version:
    ifneq ($(REMOTE_BRANCH),)
      ifneq ($(LOCAL_BRANCH),$(RELEASE_BRANCH))
	$(error Must be on ${RELEASE_BRANCH}, not ${LOCAL_BRANCH})
      endif
    endif

compare-images: branch-matches-version upstream-images compare-prep
	$(eval PREV_RAW := "$(shell grep -rhoE 'image:.*' ./${PREV_RELEASE}/${BUILD}/templates | sort -u)")
# NB: sed cleans up image prefix, quotes, and matches '{{ registry|default('k8s.gcr.io') }}/foo-{{ bar }}:latest', replacing the first {{..}} with the specified default registry
	$(eval PREV_IMAGES := $(shell echo ${PREV_RAW} | sed -E -e "s/image: //g" -e "s/\{\{ registry\|default\(([^}]*)\) }}/\1/g" -e "s/['\"]//g"))
# NB: compare image lists, only keeping those unique to UPSTREAM_IMAGES
	$(eval NEW_IMAGES := $(shell bash -c "comm -13 <(echo ${PREV_IMAGES} | tr ' ' '\n' | sort) <(echo ${UPSTREAM_IMAGES} | tr ' ' '\n' | sort) | tr '\n' ' '"))
	@echo "${KUBE_VERSION}-versus-${PREV_RELEASE}: ${NEW_IMAGES}"
