// ROS 2 Humble binary compatibility for ros-humble-mavros 2.14.0.
//
// diagnostic_updater 4.0.6 moved Updater's implementation into its header and
// no longer ships libdiagnostic_updater.so.  The current Humble MAVROS Debian
// binary was nevertheless linked against that library and its former exported
// constructor/vtable.  Instantiating Updater in this translation unit emits
// those inline ABI symbols into a library with the name MAVROS expects.

#include <memory>
#include <new>
#include <utility>

#include "diagnostic_updater/diagnostic_updater.hpp"

extern "C" __attribute__((visibility("default")))
void diagnostic_updater_emit_humble_abi(
  std::shared_ptr<rclcpp::node_interfaces::NodeBaseInterface> base_interface,
  std::shared_ptr<rclcpp::node_interfaces::NodeClockInterface> clock_interface,
  std::shared_ptr<rclcpp::node_interfaces::NodeLoggingInterface> logging_interface,
  std::shared_ptr<rclcpp::node_interfaces::NodeParametersInterface> parameters_interface,
  std::shared_ptr<rclcpp::node_interfaces::NodeTimersInterface> timers_interface,
  std::shared_ptr<rclcpp::node_interfaces::NodeTopicsInterface> topics_interface)
{
  diagnostic_updater::Updater updater(
    std::move(base_interface),
    std::move(clock_interface),
    std::move(logging_interface),
    std::move(parameters_interface),
    std::move(timers_interface),
    std::move(topics_interface));
}

// MAVROS 2.14.0 was compiled against Updater's previous constructor. Its last
// byte selected the diagnostics publisher QoS; the new header uses the Humble
// default directly. Export the old mangled constructor and delegate to the new
// in-place implementation, retaining the current default behavior.
extern "C" __attribute__((visibility("default")))
void diagnostic_updater_legacy_constructor(
  diagnostic_updater::Updater * self,
  std::shared_ptr<rclcpp::node_interfaces::NodeBaseInterface> base_interface,
  std::shared_ptr<rclcpp::node_interfaces::NodeClockInterface> clock_interface,
  std::shared_ptr<rclcpp::node_interfaces::NodeLoggingInterface> logging_interface,
  std::shared_ptr<rclcpp::node_interfaces::NodeParametersInterface> parameters_interface,
  std::shared_ptr<rclcpp::node_interfaces::NodeTimersInterface> timers_interface,
  std::shared_ptr<rclcpp::node_interfaces::NodeTopicsInterface> topics_interface,
  double period,
  unsigned char)
  asm("_ZN18diagnostic_updater7UpdaterC1ESt10shared_ptrIN6rclcpp15node_interfaces17NodeBaseInterfaceEES1_INS3_18NodeClockInterfaceEES1_INS3_20NodeLoggingInterfaceEES1_INS3_23NodeParametersInterfaceEES1_INS3_19NodeTimersInterfaceEES1_INS3_19NodeTopicsInterfaceEEdh");

extern "C"
void diagnostic_updater_legacy_constructor(
  diagnostic_updater::Updater * self,
  std::shared_ptr<rclcpp::node_interfaces::NodeBaseInterface> base_interface,
  std::shared_ptr<rclcpp::node_interfaces::NodeClockInterface> clock_interface,
  std::shared_ptr<rclcpp::node_interfaces::NodeLoggingInterface> logging_interface,
  std::shared_ptr<rclcpp::node_interfaces::NodeParametersInterface> parameters_interface,
  std::shared_ptr<rclcpp::node_interfaces::NodeTimersInterface> timers_interface,
  std::shared_ptr<rclcpp::node_interfaces::NodeTopicsInterface> topics_interface,
  double period,
  unsigned char)
{
  new (self) diagnostic_updater::Updater(
    std::move(base_interface),
    std::move(clock_interface),
    std::move(logging_interface),
    std::move(parameters_interface),
    std::move(timers_interface),
    std::move(topics_interface),
    period);
}
