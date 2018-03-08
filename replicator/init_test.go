package replicator_test

import (
	"fmt"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"

	"testing"
)

var (
	pathToMain string
)

func TestReplicator(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "replicator")
}

func formatLogLine(s string, v []interface{}) string {
	return fmt.Sprintf(s, v...)
}
