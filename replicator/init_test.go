package replicator_test

import (
	"fmt"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
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
