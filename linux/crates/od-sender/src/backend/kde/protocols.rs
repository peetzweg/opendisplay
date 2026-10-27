//! Client code for the two KDE protocols (`crates/od-sender/protocols/`,
//! LGPL-2.1-or-later, from plasma-wayland-protocols).
#![allow(
    dead_code,
    unused_imports,
    non_upper_case_globals,
    non_camel_case_types,
    clippy::all
)]

pub mod screencast {
    use wayland_client;
    use wayland_client::protocol::*;

    pub mod __interfaces {
        use wayland_client::protocol::__interfaces::*;
        wayland_scanner::generate_interfaces!("protocols/zkde-screencast-unstable-v1.xml");
    }
    use self::__interfaces::*;

    wayland_scanner::generate_client_code!("protocols/zkde-screencast-unstable-v1.xml");
}

pub mod fake_input {
    use wayland_client;
    use wayland_client::protocol::*;

    pub mod __interfaces {
        use wayland_client::protocol::__interfaces::*;
        wayland_scanner::generate_interfaces!("protocols/fake-input.xml");
    }
    use self::__interfaces::*;

    wayland_scanner::generate_client_code!("protocols/fake-input.xml");
}

pub mod output_device {
    use wayland_client;
    use wayland_client::protocol::*;

    pub mod __interfaces {
        use wayland_client::protocol::__interfaces::*;
        wayland_scanner::generate_interfaces!("protocols/kde-output-device-v2.xml");
    }
    use self::__interfaces::*;

    wayland_scanner::generate_client_code!("protocols/kde-output-device-v2.xml");
}

pub mod output_management {
    use super::output_device::*;
    use wayland_client;
    use wayland_client::protocol::*;

    pub mod __interfaces {
        use super::super::output_device::__interfaces::*;
        use wayland_client::protocol::__interfaces::*;
        wayland_scanner::generate_interfaces!("protocols/kde-output-management-v2.xml");
    }
    use self::__interfaces::*;

    wayland_scanner::generate_client_code!("protocols/kde-output-management-v2.xml");
}
