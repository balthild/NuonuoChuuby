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
		// Pure types and policies, with nothing below them.
		.target(name: "PetFoundation"),
		// Reading the desktop, and describing where things can be drawn.
		.target(name: "PetDesktop", dependencies: ["PetFoundation"]),
		// Loading and playing the artwork and the voice.
		.target(name: "PetMedia", dependencies: ["PetFoundation"]),
		// Her state, her drives, and what she does about them.
		.target(
			name: "PetBehaviour",
			dependencies: ["PetFoundation", "PetDesktop", "PetMedia"]
		),
		// The pet herself: her brain, her body and her overlay.
		.target(
			name: "Pet",
			dependencies: ["PetFoundation", "PetDesktop", "PetMedia", "PetBehaviour"]
		),
		// The app shell: the menu bar, and everything wired together.
		.target(
			name: "PetApp",
			dependencies: ["PetFoundation", "PetDesktop", "PetMedia", "PetBehaviour", "Pet"]
		),
		.executableTarget(name: "NuonuoChuuby", dependencies: ["PetApp"]),
		.testTarget(
			name: "NuonuoChuubyTests",
			dependencies: [
				"PetFoundation", "PetDesktop", "PetMedia", "PetBehaviour", "Pet", "PetApp",
			]
		),
	]
)
