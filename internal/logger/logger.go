package logger

import (
	"context"
	"log/slog"
	"os"
)

// LevelFatal is a custom slog level above ERROR. Logging at this level
// will print the message and exit the process with code 1.
const LevelFatal = slog.Level(12)

func init() {
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
		ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
			if a.Key == slog.LevelKey {
				if a.Value.Any().(slog.Level) == LevelFatal {
					a.Value = slog.StringValue("FATAL")
				}
			}
			return a
		},
	})
	slog.SetDefault(slog.New(h))
}

// Fatal logs at FATAL level then exits with code 1.
func Fatal(msg string, args ...any) {
	slog.Log(context.Background(), LevelFatal, msg, args...)
	os.Exit(1)
}
