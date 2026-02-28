package common

import "os"

// osUserHomeDir wraps os.UserHomeDir so the os import stays isolated.
func osUserHomeDir() (string, error) {
	return os.UserHomeDir()
}
