package hop

import "testing"

func TestTCPFrameCap(t *testing.T) {
	if !frameLenOK(MaxFrameBytes) {
		t.Fatal("frame at cap must be accepted")
	}
	if frameLenOK(MaxFrameBytes+1) || frameLenOK(^uint32(0)) {
		t.Fatal("oversized frame header must be rejected before allocation")
	}
}
