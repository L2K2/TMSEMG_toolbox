# TMS-EMG toolbox

A toolbox for TMS-EMG experiments.

The toolbox contains four distinct elements.

1. **BrainVisionRDA** - A MATLAB class to receive data from the BrainVision Recorder (a capture software for BrainVision ExG amplifier) via its remote data access (RDA) interface.

2. **MagProController** - A MATLAB class to control a MagVenture MagPro TMS device.
	1. This class can be used also separately from the rest of the toolbox.
	2. In its standalone mode, the class contains a superset of features of the 'MAGIC' toolbox ( https://github.com/nigelrogasch/MAGIC ). In addition to control of the MagPro device, the class listens to the output by the MagPro device (such as adjustments to stimulation amplitude on the device front panel or on the coil, realized di/dt of each pulse, change of coil\*, changes in the coil temperature, ...).
		1. The device should support all messages the device sends. This has the added benefit that unlike with 'MAGIC' with **MagProController** does not need to repeatedly 'disconnect' and 'connect' before certain command such as reading the device state. This reduces the time to adjust certain parameters in the device from several seconds to a few milliseconds.
		2. This needed a complete rewrite from scratch, as in **MagProController** there has to be a separate background event listener to listen to the device serial output. This also allowed migration to the new serial port class for MATLAB R2019b or newer (the class also supports the older MATLAB versions).
		3. Consequently, **MagProController** does not share the format of TMS device classes in 'MAGIC'. It might be possible to write a wrapper to contain a subset of its features, and any user is welcome to do so. This might become relevant when the support for the old serial interface is removed from MATLAB (currently marked as 'to be removed' in R2021a).
	3. 	The class contains an internal log-file functionality, however, it in standalone mode it cannot resolve the known issue of 'undefined behavior' of the MagPro serial output (i.e., for some paired pulses, the TMS device randomly sends either one or two serial messages to describe the delivered di/dt), as resolving this requires external hardware which is controlled separately by the main toolbox class.

3. **MEP** - A MATLAB class to remove the TMS artefact from a TMS-EMG epoch and to automatically determine the MEP amplitude.

4. **TMSEMG** - A MATLAB appdesigner application.
	1. The toolbox requires R2020a or newer to support the event listener, the original R2019b appdesigner lacks an eventlistener for the keyboard, needed for the foot pedal.
	2. A plain-text copy has been exported to 'TMSEMG_exported.m'. It can be used identically to the 'TMSEMG.mlapp' on MATLAB, but to retain the ability to develop the application further within the appdesigner, the edits should be made to the binary .mlapp file and then exported to such a plain-text file with its 'Save As' feature for others to use.

The toolbox requires Parallel Processing toolbox (as MATLAB environment does not have general purpose threads). This is used to run the **BrainVisionRDA** in the background to ensure that each UDP data packet (every 10-20 ms) is received. This class builds a buffer of the data for the (relatively) much slower UI. Total delay from pulse to screen is about the length of the data window + a few tens of milliseconds.

In addtion, the **BrainVisionRDA** requires, and the repository contains, the pnet toolbox by Peter Rydesäter for the UDP data. This is used for communication between the ExG software and MATLAB. The pnet toolbox is licensed under GPL.

(\*) For changes in coil, the toolbox only reports the ID number of the coil type. I have not asked for a full list of ID to human-readable from MagVenture. If they provide such a list, it can be added to the toolbox. If not, we will need to crowd source the mapping ourselves. The device does not send the human-readable coil name, but rather just an unique integer.

## References

Peter Rydesäter (2022). TCP/UDP/IP Toolbox 2.0.6 (https://www.mathworks.com/matlabcentral/fileexchange/345-tcp-udp-ip-toolbox-2-0-6), MATLAB Central File Exchange. Retrieved February 22, 2022.