// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
	name: "NuonuoChuuby",
	platforms: [
		.macOS(.v14)
	],
	products: [
		.executable(name: "NuonuoChuuby", targets: ["NuonuoChuuby"])
	],
	targets: [
		.target(name: "NuonuoChuubyCore"),
		.executableTarget(
			name: "NuonuoChuuby",
			dependencies: [
				.target(name: "NuonuoChuubyCore")
			]
		),
		.testTarget(
			name: "NuonuoChuubyCoreTests",
			dependencies: [
				.target(name: "NuonuoChuubyCore")
			]
		),
	]
)
