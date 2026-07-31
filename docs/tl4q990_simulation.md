# TL4Q990-class PX4 simulation

This vehicle is an engineering approximation of a Tarot TL4Q990-sized
quadrotor. It is intended for autonomy-stack and controller testing; it is not
a digital twin of a particular motor, propeller, battery, payload, or frame.

## Run it

Build the normal simulation images/workspaces first if they have not already
been built. Then start the same stack used by the x500, with the dedicated
Compose file:

```bash
docker compose \
  -f docker-compose.sim_crete_px4_tl4q990.yml \
  --profile launch up
```

For a machine without a display, prefix the command with
`GZ_HEADLESS=true`. The first run recompiles PX4 SITL because the vehicle has a
dedicated airframe entry and can therefore take longer than later runs.

To stop and remove the containers:

```bash
docker compose \
  -f docker-compose.sim_crete_px4_tl4q990.yml \
  --profile launch down
```

## Initial physical assumptions

| Property | Value |
| --- | ---: |
| Diagonal motor wheelbase | 0.990 m |
| Total simulated mass | 6.50 kg |
| Body / payload mass | 5.80 kg |
| Rotor mass | 0.12 kg each |
| Lidar mass | 0.22 kg |
| Propeller diameter | 0.533 m (21-inch class) |
| Maximum rotor speed | 800 rad/s |
| Motor thrust coefficient | 6.5e-5 N/(rad/s)^2 |
| Approximate maximum thrust-to-weight | 2.61 |
| Nominal PX4 hover throttle | 0.55 |

The model uses primitive geometry so that its collision envelope and inertia
are useful even without Tarot CAD assets. Its rotor-disc envelope is about
1.25 m square. GBPlanner uses that larger envelope instead of the x500's 0.4 m
box.

## Where to tune it

- Gazebo geometry, masses, inertia, sensors, and motor dynamics:
  `workspaces/robot_bringup/gz/models/tl4q990_3d_lidar/model.sdf`
- PX4 rotor positions, ESC output range, hover throttle, and initial rate
  gains:
  `workspaces/PX4/ROMFS/px4fmu_common/init.d-posix/airframes/4026_gz_tl4q990_3d_lidar`
- NMPC mass, inertia, allocation, size, and limits:
  `workspaces/robot_bringup/config/ros2/tl4q990/nmpc_config.yaml`
- Planner collision envelope:
  `workspaces/robot_bringup/config/ros1/gbplanner/tl4q990/gbplanner_config.yaml`

When changing payload mass, update both the SDF link mass/inertia and the NMPC
robot mass/inertia. Recalculate the hover setting from

```text
omega_hover = sqrt(mass * gravity / (4 * motor_constant))
hover_throttle = (omega_hover - esc_min) / (esc_max - esc_min)
```

For this first-pass model, that gives approximately 494 rad/s and a throttle
of 0.55. Keep enough maximum-thrust margin after a payload change; a practical
simulation starting point is at least 1.8:1 thrust-to-weight.

For higher fidelity, replace the assumed propulsion constants with data from a
motor/propeller thrust stand, and replace the inertia tensor with a CAD or
pendulum-based estimate. Tune PX4 rate control only after mass, inertia,
propulsion, center of gravity, and motor ordering have been checked.
