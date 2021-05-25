package acceptance

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
)

const IST_OUTPUT = `replicating %s to %s
adding: metadata/
adding: migrations/
adding: releases/
adding: metadata/p-isolation-segment.yml
updating job: isolated_ha_proxy => isolated_ha_proxy_blue
updating job: isolated_router => isolated_router_blue
updating job: isolated_diego_cell => isolated_diego_cell_blue
adding: migrations/v1/
adding: releases/some-release.tgz
done`

const WRT_2012_OUTPUT = `replicating %s to %s
adding: metadata/
adding: metadata/p-windows-runtime.yml
updating job: windows_diego_cell => windows_diego_cell_indigo
updating job: an_errand => an_errand_indigo
adding: migrations/
adding: migrations/v1/
adding: releases/
adding: releases/some-release.tgz
done`

const WRT_2016_OUTPUT = `replicating %s to %s
adding: embed/
adding: embed/scripts/
adding: embed/scripts/run
adding: metadata/
adding: metadata/p-windows-runtime.yml
updating job: windows_diego_cell => windows_diego_cell_aquamarine
updating job: an_errand => an_errand_aquamarine
adding: migrations/
adding: migrations/v1/
adding: releases/
adding: releases/some-release.tgz
done`

var _ = Describe("replicator", func() {
	Context("when replicating the isolation segment tile", func() {
		It("writes a file without erroring", func() {
			pathToTile := filepath.Join("..", "fixtures", "ist.pivotal")
			pathToOutputTile := filepath.Join(os.TempDir(), "ist-duplicated.pivotal")

			command := exec.Command(pathToMain,
				"--path", pathToTile,
				"--output", pathToOutputTile,
				"--name", "blue")

			session, err := gexec.Start(command, GinkgoWriter, GinkgoWriter)
			Eventually(session).Should(gexec.Exit(0))
			Expect(err).NotTo(HaveOccurred())

			Expect(pathToOutputTile).To(BeAnExistingFile())

			Expect(session.Out.Contents()).To(ContainSubstring(fmt.Sprintf(IST_OUTPUT, pathToTile, pathToOutputTile)))
		})
	})

	Context("when replicating the windows 2012 runtime tile", func() {
		It("writes a file without erroring", func() {
			pathToTile := filepath.Join("..", "fixtures", "wrt.pivotal")
			pathToOutputTile := filepath.Join(os.TempDir(), "wrt-duplicated.pivotal")

			command := exec.Command(pathToMain,
				"--path", pathToTile,
				"--output", pathToOutputTile,
				"--name", "indigo")

			session, err := gexec.Start(command, GinkgoWriter, GinkgoWriter)
			Eventually(session).Should(gexec.Exit(0))
			Expect(err).NotTo(HaveOccurred())

			Expect(pathToOutputTile).To(BeAnExistingFile())

			Expect(session.Out.Contents()).To(ContainSubstring(fmt.Sprintf(WRT_2012_OUTPUT, pathToTile, pathToOutputTile)))
		})
	})

	Context("when replicating the windows 2016 runtime tile", func() {
		It("writes a file without erroring", func() {
			pathToTile := filepath.Join("..", "fixtures", "wrt-2016.pivotal")
			pathToOutputTile := filepath.Join(os.TempDir(), "wrt-2016-duplicated.pivotal")

			command := exec.Command(pathToMain,
				"--path", pathToTile,
				"--output", pathToOutputTile,
				"--name", "aquamarine")

			session, err := gexec.Start(command, GinkgoWriter, GinkgoWriter)
			Eventually(session).Should(gexec.Exit(0))
			Expect(err).NotTo(HaveOccurred())

			Expect(pathToOutputTile).To(BeAnExistingFile())

			Expect(session.Out.Contents()).To(ContainSubstring(fmt.Sprintf(WRT_2016_OUTPUT, pathToTile, pathToOutputTile)))
		})
	})
})
