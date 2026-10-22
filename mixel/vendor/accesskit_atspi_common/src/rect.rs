// Copyright 2022 The AccessKit Authors. All rights reserved.
// Licensed under the Apache License, Version 2.0 (found in
// the LICENSE-APACHE file) or the MIT license (found in
// the LICENSE-MIT file), at your option.

use serde::{Deserialize, Serialize};
use zbus::{OwnedVariant, Type, Variant};

#[derive(
    Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize, OwnedVariant, Type, Variant,
)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl Rect {
    pub const INVALID: Rect = Rect {
        x: -1,
        y: -1,
        width: -1,
        height: -1,
    };
}

impl From<accesskit::Rect> for Rect {
    fn from(value: accesskit::Rect) -> Rect {
        Rect {
            x: value.x0 as i32,
            y: value.y0 as i32,
            width: value.width() as i32,
            height: value.height() as i32,
        }
    }
}

#[cfg(test)]
mod wire_tests {
    use super::Rect;
    use zbus::{
        Type,
        wire::{BE, LE, serialized::Context, to_bytes},
    };

    #[test]
    fn rectangle_wire_bytes_keep_signed_coordinates_and_integer_extents() {
        let rectangle = Rect {
            x: -1,
            y: 2,
            width: 640,
            height: 480,
        };
        assert_eq!(Rect::SIGNATURE.to_string(), "(iiii)");
        let little = to_bytes(Context::new(LE, 0), &rectangle).unwrap();
        assert_eq!(
            little.bytes(),
            &[255, 255, 255, 255, 2, 0, 0, 0, 128, 2, 0, 0, 224, 1, 0, 0]
        );
        assert_eq!(little.deserialize::<Rect>().unwrap().0, rectangle);
        let big = to_bytes(Context::new(BE, 0), &rectangle).unwrap();
        assert_eq!(
            big.bytes(),
            &[255, 255, 255, 255, 0, 0, 0, 2, 0, 0, 2, 128, 0, 0, 1, 224]
        );
        assert_eq!(big.deserialize::<Rect>().unwrap().0, rectangle);
    }
}
