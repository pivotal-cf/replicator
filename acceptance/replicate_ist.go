package acceptance

import (
	"os"
	"os/exec"
	"path/filepath"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
)

var _ = Describe("replicate ist", func() {
	It("duplicates the tile and gives it the provided name", func() {
		pathToTile := filepath.Join("tiles", "ist.pivotal")
		pathToOutputTile := filepath.Join(os.TempDir(), "tile-output.pivotal")

		command := exec.Command(pathToMain,
			"--path", pathToTile,
			"--output", pathToOutputTile,
			"--name", "blue")

		session, err := gexec.Start(command, GinkgoWriter, GinkgoWriter)
		Eventually(session).Should(gexec.Exit(0))
		Expect(err).NotTo(HaveOccurred())

		Expect(pathToOutputTile).To(BeAnExistingFile())

	})

})
