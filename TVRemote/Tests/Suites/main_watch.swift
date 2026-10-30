import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
await runConnectionTests()
await runWatchTests()
finish()
