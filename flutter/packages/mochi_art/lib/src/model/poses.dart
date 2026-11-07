// The pose vocabulary (Sources/TamagotchiCore/Animation/Poses.swift) lives in mochi_world, which also evaluates the
// poses; the renderers here draw those very types. Enum case names equal the Swift raw values and JSON keys the Swift
// property names, so poses exported from Swift (flutter/tools/pose_export) map straight onto them.

export 'package:mochi_world/mochi_world.dart'
    show
        AntennaTint,
        Brows,
        CompanionPose,
        Effect,
        EffectKind,
        HeldItem,
        LaptopPose,
        LaptopScreen,
        PetEyes,
        PetMouth,
        PetPose,
        VisorEyes,
        VisorMouth,
        bodyWidthsPerPathUnit;
